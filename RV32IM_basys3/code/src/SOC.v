// System on chip for the Basys 3: 5-stage RV32IM processor (processor.v),
// 64 kB of RAM, boot ROM, and the peripherals.
// Memory map is located at memmap.txt
//
// BOOT_FROM_SD = 1: reset into the boot ROM (bootrom.hex), which loads the
//                   program from the SD card into RAM and jumps to address 0.
//					 (WARNINGL: There is currently no bootrom.hex to test)
// BOOT_FROM_SD = 0: as the scaffold: RAM is preloaded with firmware.hex and
//                   the processor starts at address 0.
module SOC #(
    parameter BOOT_FROM_SD = 0,
    parameter CLK_HZ       = 25000000, // 25 MHz cpu clk
    parameter RAM_INIT     = "firmware.hex",
    parameter ROM_INIT     = "bootrom.hex"
) (
    input         CLK,        // 100 MHz
    input         RESET,      // centre button, active high
    output reg [15:0] LEDS,
    input  [15:0] SW,
    input  [3:0]  BTN,        // [0] up, [1] left, [2] right, [3] down
    input         RXD,
    output        TXD,
    // VGA connector
    output [3:0]  VGA_R,
    output [3:0]  VGA_G,
    output [3:0]  VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    // SD card in SPI mode (Pmod MicroSD on JA)
    output reg    SD_CS,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_SCK
);

   wire clk;
   wire resetn;
   wire reset = !resetn;      // the processor and peripherals use active-high reset

   Clockworks CW(
     .CLK(CLK),
     .RESET(RESET),
     .clk(clk),
     .resetn(resetn)
   );

   wire [31:0] imem_addr;
   wire        imem_en;
   wire [31:0] imem_rdata;
   wire [31:0] mem_addr;
   wire [31:0] mem_rdata;
   wire        mem_read_signal;
   wire [31:0] mem_wdata;
   wire [3:0]  mem_wmask;
   wire        halted;

   Processor #(
      .RESET_ADDR(BOOT_FROM_SD ? 32'h00800000 : 32'h00000000)
   ) CPU(
      .clk(clk),
      .reset(reset),
      .imem_addr(imem_addr),
      .imem_en(imem_en),
      .imem_rdata(imem_rdata),
      .mem_addr(mem_addr),
      .mem_rdata(mem_rdata),
      .mem_read_signal(mem_read_signal),
      .mem_wdata(mem_wdata),
      .mem_wmask(mem_wmask),
      .halted(halted)
   );

   //------------------------------ address decode ------------------------------
   wire isROM = mem_addr[23];
   wire isIO  = !mem_addr[23] &  mem_addr[22] & !mem_addr[21];
   wire isVGA = !mem_addr[23] &  mem_addr[22] &  mem_addr[21];
   wire isRAM = !mem_addr[23] & !mem_addr[22];
   wire mem_wstrb = |mem_wmask;
   wire [29:0] mem_wordaddr = mem_addr[31:2];

   //----------------------------------- RAM ------------------------------------
   wire [31:0] RAM_rdata, RAM_irdata;
   Memory #(
      .WORDS(16384),
      .INIT_FILE(BOOT_FROM_SD ? "" : RAM_INIT)
   ) RAM(
      .clk(clk),
      .imem_addr(imem_addr),
      .imem_en(imem_en & !imem_addr[23]),
      .imem_rdata(RAM_irdata),
      .mem_addr(mem_addr),
      .mem_rdata(RAM_rdata),
      .mem_read_signal(isRAM & mem_read_signal),
      .mem_wdata(mem_wdata),
      .mem_wmask({4{isRAM}} & mem_wmask)
   );

   //--------------------------------- boot ROM ---------------------------------
   wire [31:0] ROM_rdata, ROM_irdata;
   reg         fetch_rom;          // the word on imem_rdata comes from the ROM
   generate
      if (BOOT_FROM_SD) begin : g_rom
         Memory #(
            .WORDS(2048),
            .INIT_FILE(ROM_INIT),
            .WRITABLE(0)
         ) ROM(
            .clk(clk),
            .imem_addr(imem_addr),
            .imem_en(imem_en & imem_addr[23]),
            .imem_rdata(ROM_irdata),
            .mem_addr(mem_addr),
            .mem_rdata(ROM_rdata),
            .mem_read_signal(isROM & mem_read_signal),
            .mem_wdata(32'b0),
            .mem_wmask(4'b0)
         );
      end else begin : g_norom
         assign ROM_rdata  = 32'b0;
         assign ROM_irdata = 32'b0;
      end
   endgenerate

   always @(posedge clk) begin
      if (imem_en) fetch_rom <= imem_addr[23];
   end
   assign imem_rdata = fetch_rom ? ROM_irdata : RAM_irdata;

   //----------------------------------- IO -------------------------------------
   localparam IO_LEDS_bit      = 0;
   localparam IO_UART_DAT_bit  = 1;
   localparam IO_UART_CNTL_bit = 2;
   localparam IO_SPI_DAT_bit   = 3;
   localparam IO_SPI_CNTL_bit  = 4;
   localparam IO_SPI_DIV_bit   = 5;
   localparam IO_SWITCHES_bit  = 6;
   localparam IO_MILLIS_bit    = 7;

   wire io_write = isIO & mem_wstrb;
   wire io_read  = isIO & mem_read_signal;

   // LEDs
   always @(posedge clk) begin
      if (reset) LEDS <= 16'b0;
      else if (io_write & mem_wordaddr[IO_LEDS_bit]) LEDS <= mem_wdata[15:0];
   end

   // UART transmit (the scaffold's emitter)
   wire uart_valid = io_write & mem_wordaddr[IO_UART_DAT_bit];
   wire uart_ready;
   corescore_emitter_uart #(
      .clk_freq_hz(CLK_HZ),
      .baud_rate(115200)
   ) UART(
      .i_clk(clk),
      .i_rst(reset),
      .i_data(mem_wdata[7:0]),
      .i_valid(uart_valid),
      .o_ready(uart_ready),
      .o_uart_tx(TXD)
   );

   // UART receive
   wire [7:0] uart_rx_data;
   wire       uart_rx_valid, uart_rx_overrun;
   uart_rx #(
      .clk_freq_hz(CLK_HZ),
      .baud_rate(115200)
   ) UART_RX(
      .i_clk(clk),
      .i_rst(reset),
      .i_uart_rx(RXD),
      .rx_data(uart_rx_data),
      .rx_valid(uart_rx_valid),
      .rx_pop(io_read & mem_wordaddr[IO_UART_DAT_bit]),
      .overrun(uart_rx_overrun)
   );

   // SPI (SD card)
   localparam integer SPI_DIV_RESET_I = (CLK_HZ + 799999) / 800000 - 1;
   localparam [15:0]  SPI_DIV_RESET   = SPI_DIV_RESET_I[15:0];   // <= 400 kHz
   reg  [15:0] spi_div;
   wire [7:0]  spi_rx;
   wire        spi_busy;
   always @(posedge clk) begin
      if (reset) begin
         SD_CS   <= 1'b1;
         spi_div <= SPI_DIV_RESET;
      end else begin
         if (io_write & mem_wordaddr[IO_SPI_CNTL_bit]) SD_CS   <= mem_wdata[0];
         if (io_write & mem_wordaddr[IO_SPI_DIV_bit])  spi_div <= mem_wdata[15:0];
      end
   end
   spi_master SPI(
      .clk(clk),
      .reset(reset),
      .start(io_write & mem_wordaddr[IO_SPI_DAT_bit]),
      .tx_data(mem_wdata[7:0]),
      .rx_data(spi_rx),
      .busy(spi_busy),
      .clkdiv(spi_div),
      .sclk(SD_SCK),
      .mosi(SD_MOSI),
      .miso(SD_MISO)
   );

   // switches and buttons (2-flop synchronisers), millisecond counter
   reg [19:0] in_sync0, in_sync1;
   reg [31:0] millis;
   reg [15:0] ms_div;
   localparam integer MS_TICKS_I = CLK_HZ / 1000 - 1;
   localparam [15:0]  MS_LAST    = MS_TICKS_I[15:0];
   always @(posedge clk) begin
      in_sync0 <= {BTN, SW};
      in_sync1 <= in_sync0;
      if (reset) begin
         millis <= 32'b0;
         ms_div <= 16'b0;
      end else if (ms_div == MS_LAST) begin
         ms_div <= 16'b0;
         millis <= millis + 32'd1;
      end else begin
         ms_div <= ms_div + 16'd1;
      end
   end

   // IO read data, registered like a RAM read
   reg [31:0] IO_rdata;
   always @(posedge clk) begin
      if (io_read) begin
         IO_rdata <=
            mem_wordaddr[IO_LEDS_bit]      ? {16'b0, LEDS} :
            mem_wordaddr[IO_UART_DAT_bit]  ? {24'b0, uart_rx_data} :
            mem_wordaddr[IO_UART_CNTL_bit] ? {21'b0, uart_rx_overrun, !uart_ready, uart_rx_valid, 8'b0} :
            mem_wordaddr[IO_SPI_DAT_bit]   ? {24'b0, spi_rx} :
            mem_wordaddr[IO_SPI_CNTL_bit]  ? {23'b0, spi_busy, 7'b0, SD_CS} :
            mem_wordaddr[IO_SPI_DIV_bit]   ? {16'b0, spi_div} :
            mem_wordaddr[IO_SWITCHES_bit]  ? {12'b0, in_sync1} :
            mem_wordaddr[IO_MILLIS_bit]    ? millis :
                                             32'b0;
      end
   end

   //------------------------------ VGA text console ----------------------------
   wire [31:0] VGA_rdata;
   VgaText VGA(
      .clk_cpu(clk),
      .rst_cpu(reset),
      .io_sel(isVGA),
      .io_offset(mem_addr[12:0]),
      .io_wrData(mem_wdata),
      .io_memRead(mem_read_signal),
      .io_memWrite(mem_wstrb),
      .io_mask(mem_wmask),
      .io_rdData(VGA_rdata),
      .clk_vga(clk),
      .rst_vga(reset),
      .vga_en(1'b1),
      .vga_hs(VGA_HS),
      .vga_vs(VGA_VS),
      .vga_r(VGA_R),
      .vga_g(VGA_G),
      .vga_b(VGA_B)
   );

   //------------------------------ read data mux -------------------------------
   // The processor reads mem_rdata one clock after the request, when the
   // address is gone, so remember which block was addressed.
   reg [1:0] rd_sel;
   always @(posedge clk) begin
      if (mem_read_signal) rd_sel <= isROM ? 2'd3 : isVGA ? 2'd2 : isIO ? 2'd1 : 2'd0;
   end
   assign mem_rdata = (rd_sel == 2'd3) ? ROM_rdata :
                      (rd_sel == 2'd2) ? VGA_rdata :
                      (rd_sel == 2'd1) ? IO_rdata  : RAM_rdata;

endmodule
