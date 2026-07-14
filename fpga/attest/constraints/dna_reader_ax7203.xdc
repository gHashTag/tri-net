# dna_reader_ax7203.xdc — timing + pin constraints for the DNA-reader
# primitive on AX7203 (Xilinx xc7a200t-fbg484, IDCODE 0x13636093).
#
# Target: 100 MHz reference clock on bank 34 pin R4 (SYSCLK on AX7203).
# CLK_PERIOD_NS = 10.0.
#
# Ratchet 2/4 target: synthesise + P&R with WNS >= -0.5 ns.
#
# phi^2 + phi^-2 = 3

# Primary reference clock (100 MHz)
create_clock -period 10.000 -name sysclk [get_ports clk]

# Async reset — declare as async, no timing check
set_false_path -from [get_ports rst_n] -to [all_registers]

# Start pulse can be async from a slower control domain; treat as async
# input synchronised inside the DUT (the FSM latches on posedge clk).
set_false_path -from [get_ports start] -to [all_registers]

# DNA_PORT is a hard macro; no explicit pin constraints needed. The tool
# infers placement in the CFG_IO_ACCESS block automatically for 7-series.

# Suggested pin bindings on AX7203 (not required for synth-only run):
#   set_property PACKAGE_PIN R4  [get_ports clk]
#   set_property IOSTANDARD LVCMOS33 [get_ports clk]
#   set_property PACKAGE_PIN T4  [get_ports rst_n]
#   set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
