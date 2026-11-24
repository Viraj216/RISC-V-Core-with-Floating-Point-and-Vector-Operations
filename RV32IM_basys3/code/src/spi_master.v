// SPI master, mode 0 (SCLK idle low, MOSI changes on the falling edge, MISO
// sampled at the end of the high phase), 8-bit transfers, MSB first. This is
// what an SD card in SPI mode needs. Chip select is a plain register in the
// SoC so one command/response sequence can span many byte transfers.
//
//   start + tx_data : begin a transfer (ignored while busy)
//   rx_data         : byte received by the last transfer
//   clkdiv          : SCLK = clk / (2 * (clkdiv + 1)); use clkdiv >= 1
module spi_master (
    input             clk,
    input             reset,
    input             start,
    input      [7:0]  tx_data,
    output reg [7:0]  rx_data,
    output            busy,
    input      [15:0] clkdiv,
    output reg        sclk,
    output reg        mosi,
    input             miso
);
   reg [15:0] cnt;
   reg [7:0]  shift;
   reg [4:0]  edges;        // remaining half-periods (16 per byte)
   reg        start_q;      // one cycle between the write and the first edge
   reg        miso_q;       // MISO is synchronous to our own SCLK: one register

   assign busy = (edges != 0) | start_q;

   always @(posedge clk) miso_q <= miso;

   always @(posedge clk) begin
      if (reset) begin
         sclk <= 1'b0; mosi <= 1'b1; shift <= 8'hFF; rx_data <= 8'h00;
         edges <= 0; cnt <= 0; start_q <= 1'b0;
      end else begin
         start_q <= 1'b0;
         if (start & !busy) begin
            shift   <= tx_data;
            start_q <= 1'b1;
         end else if (start_q) begin
            mosi  <= shift[7];                 // first bit out, SCLK still low
            edges <= 5'd16;
            cnt   <= 0;
         end else if (edges != 0) begin
            if (cnt == clkdiv) begin
               cnt  <= 0;
               sclk <= ~sclk;
               if (sclk) begin                 // falling edge: sample, next bit out
                  shift <= {shift[6:0], miso_q};
                  mosi  <= shift[6];
               end
               edges <= edges - 5'd1;
               if (edges == 5'd1) begin        // 16th edge: byte complete
                  rx_data <= {shift[6:0], miso_q};
                  mosi    <= 1'b1;
               end
            end else begin
               cnt <= cnt + 16'd1;
            end
         end
      end
   end
endmodule
