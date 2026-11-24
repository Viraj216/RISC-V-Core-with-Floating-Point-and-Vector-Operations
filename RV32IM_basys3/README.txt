RV32IM pipeline SoC for the Basys 3 - minimal Vivado package

Works the same on Windows and Linux. Nothing but Vivado is needed
(with Artix-7 device support installed).

Contents
  setup.tcl        WIP
  code/src/        design sources + bootrom.hex + firmware.hex
  code/cons/       basys3.xdc (pins and clock)
  code/sim/        tb_soc.v (simulation testbench)
  sdcard/          WIP demo program for the SD card

Build:
WIP setup.tcl script

Run
Monitor on the VGA connector. Reset = centre button.
UART = 115200 baud, 8N1, on the USB cable.

With an SD card:
WIP  

Without an SD card:
in code/src/SOC.v change   parameter BOOT_FROM_SD = 1   to   0
and generate the bitstream again. The demo in firmware.hex then
runs straight from power-up.

Simulate
Flow Navigator > Run Simulation > Run Behavioral Simulation.
The Tcl console should print "vga_hello done" and
"processor halted (ebreak), LEDS = 0005".
