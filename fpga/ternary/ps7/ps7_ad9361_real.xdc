create_clock -period 32.552 -name fclk0 [get_nets FCLKCLK[0]]
# The bank-34 run identified as single-ended inputs in the vendor bitstream.
# Order within rx_data_in is NOT known -- the bitstream says which pins are
# inputs, not which bit each carries. A wrong order permutes the samples; it
# cannot cause contention, because every one of these is an input here too.
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS18} [get_ports rx_clk_in]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS18} [get_ports rx_frame_in]
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[0]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[1]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[2]}]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[3]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[4]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[5]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[6]}]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[7]}]
set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[8]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[9]}]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[10]}]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS18} [get_ports {rx_data_in[11]}]
