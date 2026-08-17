# Timing constraints for ps7_corr.
#
# Every Fmax figure this project has ever quoted was produced with NO timing
# constraint at all: `build/ps7_corr.xdc` and `build/ps7_probe.xdc` are zero
# bytes, `create_clock` appears nowhere in the repository, and
# `build/REPRODUCTION.log` contains two runs of the same design reporting
# 186.05 MHz and 308.07 MHz -- both annotated "PASS at 12.00 MHz", which is
# nextpnr's default target when it is given nothing to aim at.
#
# An unconstrained nextpnr result is not a measurement. It is the delay of
# whatever path the router happened to leave longest, on a seed it happened to
# pick. Constrain the design, then quote WNS -- or quote nothing.
#
# FCLKCLK[0] is the PS-supplied fabric clock. 30.72 MHz is the AD9361 rate this
# design is intended to sit behind (61.44 MSPS complex = 30.72 MHz per I/Q
# lane); constrain there first, confirm positive slack, then walk the period
# down to find the real ceiling rather than guessing it.
create_clock -period 32.552 -name fclk0 [get_nets FCLKCLK[0]]

# The EMIO GPIO word crosses from the PS clock domain into the fabric. Both
# ps7_corr.v and ps7_probe.v synchronise strobe, c_wr and rst through two flops
# before use, so the raw EMIO inputs are deliberately asynchronous and must not
# be timed as if they were not. Without this the tool will chase paths that the
# synchronisers exist precisely to make harmless.
set_false_path -from [get_nets {gpio_o[*]}] -to [get_pins -hierarchical *_sync_reg[0]/D]

# Note on the part. run_openxc7.sh builds xc7z020clg400-1 (speed grade -1),
# while docs/FPGA_UTILIZATION_AND_COMPETITORS.md claims XC7Z020-2CLG400I
# (speed grade -2, industrial). These are different silicon bins and every
# number below moves between them. Pick one, put it in both places, and say
# which one the quoted slack belongs to.
