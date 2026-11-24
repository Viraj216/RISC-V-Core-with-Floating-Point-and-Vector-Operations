// Clock and reset for the Basys 3.
//
//   CLK    100 MHz board oscillator
//   RESET  centre push button, active HIGH (Basys 3 buttons read 0 at rest)
//   clk    25 MHz system clock from a PLL: it is at the same time the CPU
//          clock and the 640x480@60 pixel clock, so the design has a single
//          clock domain
//   resetn low while the button is pressed, while the PLL is not locked, and
//          for 2^16 clocks afterwards
//
// Note that resetn is active LOW. The scaffold connected it straight to the
// processor's active-high reset; SOC.v now inverts it.
//
// With `BENCH defined (simulation) the PLL is left out and clk = CLK.
module Clockworks (
   input  CLK,
   input  RESET,
   output clk,
   output resetn
);

`ifdef BENCH
   assign clk = CLK;
   wire   locked = 1'b1;
`else
   wire clk_fb, clk_pll, locked;
   // VCO = 100 MHz * 8 = 800 MHz, CLKOUT0 = 800 / 32 = 25 MHz
   PLLE2_BASE #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKIN1_PERIOD(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT(8),
      .CLKOUT0_DIVIDE(32),
      .CLKOUT0_DUTY_CYCLE(0.5),
      .CLKOUT0_PHASE(0.0),
      .STARTUP_WAIT("FALSE")
   ) pll (
      .CLKIN1(CLK),
      .CLKFBIN(clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0(clk_pll),
      .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
      .LOCKED(locked),
      .PWRDWN(1'b0),
      .RST(1'b0)
   );
   BUFG bufg (.I(clk_pll), .O(clk));
`endif

`ifdef BENCH
   localparam RESET_BITS = 4;      // short reset in simulation
`else
   localparam RESET_BITS = 16;
`endif
   reg [RESET_BITS-1:0] reset_cnt = 0;
   assign resetn = &reset_cnt;

   wire hold = RESET | !locked;
   always @(posedge clk, posedge hold) begin
      if (hold)         reset_cnt <= 0;
      else if (!resetn) reset_cnt <= reset_cnt + 1'b1;
   end

endmodule
