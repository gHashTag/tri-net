## SCRATCH CONSTRAINT OVERLAY -- flow validation only, NOT the B1 artefact.
## Pins chosen from prjxray-db artix7 xc7a200tfbg484-1 package_pins.csv, not
## from the board schematic. clk200_n=T4 is the verified differential mate of
## R4 (same tile RIOB33_X105Y123). LED/reset pins are arbitrary bank-34/35 IO.
set_property -dict {PACKAGE_PIN T4 IOSTANDARD DIFF_SSTL15} [get_ports clk200_n]
set_property -dict {PACKAGE_PIN AA1 IOSTANDARD LVCMOS15} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN AA5 IOSTANDARD LVCMOS15} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN AB3 IOSTANDARD LVCMOS15} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN B1 IOSTANDARD LVCMOS15} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS15} [get_ports rst_n]
