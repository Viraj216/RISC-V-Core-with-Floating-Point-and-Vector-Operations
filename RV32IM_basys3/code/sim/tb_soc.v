`timescale 1ns / 1ps
// Vivado simulation top: the SoC running firmware.hex from RAM
// (BOOT_FROM_SD = 0, so no SD card is needed). Characters sent on the UART
// are printed in the Tcl console; the VGA pins can be watched in the
// waveform. The simulation fileset defines BENCH (no PLL, clk = CLK).
module tb_soc;
   reg CLK = 0, RESET = 1;
   wire [15:0] LEDS; wire TXD;
   wire [3:0] VGA_R, VGA_G, VGA_B; wire VGA_HS, VGA_VS;
   wire SD_CS, SD_MOSI, SD_SCK;

   SOC #(.BOOT_FROM_SD(0)) dut (
      .CLK(CLK), .RESET(RESET), .LEDS(LEDS), .SW(16'h0), .BTN(4'h0), .RXD(1'b1), .TXD(TXD),
      .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
      .SD_CS(SD_CS), .SD_MOSI(SD_MOSI), .SD_MISO(1'b1), .SD_SCK(SD_SCK));

   always #20 CLK = ~CLK;          // 25 MHz, the system clock rate
   initial #130 RESET = 0;

   always @(posedge dut.clk)
      if (dut.uart_valid && dut.uart_ready) $write("%c", dut.mem_wdata[7:0]);

   always @(posedge dut.clk) if (dut.halted) begin
      $display("\nprocessor halted (ebreak), LEDS = %h", LEDS);
      $finish;
   end
endmodule
