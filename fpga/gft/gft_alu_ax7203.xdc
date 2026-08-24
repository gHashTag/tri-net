## ALINX AX7203 = XC7A200T-FBG484-2. Constraints for gft_alu_ax7203.
## Clock: 200 MHz differential, DIFF_SSTL15, clk200_p on R4 (per docs/issues-archive
## p0-ax7203-flash.md -- the proven blinky clocking; LVDS blocked DONE, use DIFF_SSTL15).
set_property -dict {PACKAGE_PIN R4 IOSTANDARD DIFF_SSTL15} [get_ports clk200_p]
## clk200_n is R4's differential mate on the same bank -- VERIFY the exact pin against the
## ALINX AX7203 schematic before P&R (documented pin is R4+; the mate is typically T4).
# set_property -dict {PACKAGE_PIN T4 IOSTANDARD DIFF_SSTL15} [get_ports clk200_n]
create_clock -period 5.000 -name sysclk [get_ports clk200_p]   ## 200 MHz

## LEDs + reset: fill PACKAGE_PIN from the board's proven XDC / ALINX schematic.
## (Not asserted here -- authoring speculative pin numbers would mislead P&R.)
# set_property -dict {PACKAGE_PIN <LED0> IOSTANDARD LVCMOS33} [get_ports {led[0]}]
# set_property -dict {PACKAGE_PIN <LED1> IOSTANDARD LVCMOS33} [get_ports {led[1]}]
# set_property -dict {PACKAGE_PIN <LED2> IOSTANDARD LVCMOS33} [get_ports {led[2]}]
# set_property -dict {PACKAGE_PIN <LED3> IOSTANDARD LVCMOS33} [get_ports {led[3]}]
# set_property -dict {PACKAGE_PIN <KEY>  IOSTANDARD LVCMOS15} [get_ports rst_n]
