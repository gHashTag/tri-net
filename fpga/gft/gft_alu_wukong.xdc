## QMTech Wukong V1 (xc7a200tfbg676-1) -- pin-complete from proven data only.
## D5/D6: the LEDs t27's find_led / static_d5 / blink_j26 lineage proved by
## flashing (fpga/HARDWARE_SSOT.md). slowclk: CFGMCLK/8 = 8.85 MHz fastest die
## (T495), against 25.46 MHz measured Fmax -- 2.9x margin, stated.
set_property -dict { PACKAGE_PIN D5 IOSTANDARD LVCMOS33 } [get_ports d5]
set_property -dict { PACKAGE_PIN D6 IOSTANDARD LVCMOS33 } [get_ports d6]
create_clock -period 113.0 -name slowclk [get_nets slowclk]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]
