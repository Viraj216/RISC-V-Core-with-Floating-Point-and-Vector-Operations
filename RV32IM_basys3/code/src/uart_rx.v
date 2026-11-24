// UART receiver, 8N1, with a 16-byte FIFO.
//   rx_valid : a byte is waiting on rx_data
//   rx_pop   : take it (one clock pulse)
//   overrun  : a byte arrived while the FIFO was full (sticky until reset)
module uart_rx #(
    parameter clk_freq_hz = 25000000,
    parameter baud_rate   = 115200
) (
    input        i_clk,
    input        i_rst,
    input        i_uart_rx,
    output [7:0] rx_data,
    output       rx_valid,
    input        rx_pop,
    output reg   overrun
);
   localparam integer DIV = clk_freq_hz / baud_rate;      // clocks per bit
   localparam integer DIV_HALF_I = DIV / 2;
   localparam integer DIV_LAST_I = DIV - 1;
   localparam [15:0]  DIV_HALF = DIV_HALF_I[15:0];
   localparam [15:0]  DIV_LAST = DIV_LAST_I[15:0];

   reg [1:0]  sync;                 // 2-flop synchroniser, idle high
   wire       rx = sync[1];
   reg [15:0] cnt;
   reg [3:0]  bitn;                 // 0 idle, 1 start, 2..9 data, 10 stop
   reg [7:0]  shift;

   reg [7:0]  fifo [0:15];
   reg [4:0]  wptr, rptr;
   wire       empty = (wptr == rptr);
   wire       full  = (wptr[3:0] == rptr[3:0]) && (wptr[4] != rptr[4]);
   assign rx_valid = !empty;
   assign rx_data  = fifo[rptr[3:0]];

   always @(posedge i_clk) begin
      sync <= {sync[0], i_uart_rx};
      if (i_rst) begin
         sync <= 2'b11; bitn <= 0; cnt <= 0; wptr <= 0; rptr <= 0; overrun <= 1'b0;
      end else begin
         if (rx_pop && !empty) rptr <= rptr + 5'd1;
         if (bitn == 0) begin
            if (!rx) begin bitn <= 4'd1; cnt <= DIV_HALF; end       // sample mid-bit
         end else if (cnt != 0) begin
            cnt <= cnt - 16'd1;
         end else begin
            cnt <= DIV_LAST;
            if (bitn == 4'd1) begin
               bitn <= rx ? 4'd0 : 4'd2;                          // false start?
            end else if (bitn == 4'd10) begin
               bitn <= 4'd0;
               if (rx) begin                                       // valid stop bit
                  if (full) overrun <= 1'b1;
                  else begin fifo[wptr[3:0]] <= shift; wptr <= wptr + 5'd1; end
               end
            end else begin
               shift <= {rx, shift[7:1]};                          // LSB first
               bitn  <= bitn + 4'd1;
            end
         end
      end
   end
endmodule
