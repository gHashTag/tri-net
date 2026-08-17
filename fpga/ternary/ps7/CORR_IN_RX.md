# The correlator inside the AD9361 receive datapath

This is what the whole exercise was for: our multiplierless 63-tap despreader
instantiated **inside** ADI's AD9361 receive core, in one bitstream, built with
no vendor tool anywhere in the chain, and loaded into real silicon.

## The design

`ps7_ad9361_corr.v`. The correlator is fed from `axi_ad9361`'s `adc_data_i0` /
`adc_valid_i0` and clocked on `l_clk` -- the recovered bus clock -- so it sits
in the receive path rather than beside it.

**Zero package pins.** Verified in the netlist rather than asserted:

```
output buffers in the netlist : NONE
top-level ports               : none
```

That matters here more than anywhere else in this project. `PINOUT.md` shows
that all 30 pins an earlier harness picked are driven by the vendor design; a
design with real outputs on those banks is unsafe to load on this board until
per-pin direction is known. This one drives nothing.

Two parameters make a portless build possible: `IODELAY_CTRL(0)` with
`FPGA_TECHNOLOGY(0)` keeps the delay controller out (with no IDELAYs
instantiated an IDELAYCTRL is orphaned and openXC7 rejects it), and it also
removes the `IDELAYE2` whose `IDATAIN` cannot be driven by a flip-flop. A sixth
patch to ADI's tree bypasses the clock `IBUF` in `ad_data_clk.v`, for the same
reason as the one in `ad_data_in.v`: openXC7 cannot place an input buffer that
is not bound to a constrained top-level port, and a portless design has none.

## Build and place

```
yosys 0.67          : LUT 12 577, FF 9 019, CARRY4 1 710, DSP48E1 12, 0 I/O buffers
nextpnr (patched)   : exit 0, 81 s, 554 654 wires, overused 0, archfail 0
  'FCLKCLK[0]'      : 113.13 MHz (PASS at 30.72 MHz)
  'lclk'            :  50.58 MHz (PASS at 12.00 MHz)  <- the AD9361 clock domain
fasm2frames + xc7frames2bit : exit 0
payload_sha256 aced28508c0c1a4dd8d22c1babbb9eff2715cfc9ba59c1a2d4a717f39f2e4e16
```

## On silicon

```
state  : operating
anchor : 0x47C0          <- our design is in the fabric
count  : 37              <- adc_valid strobes counted from the vendor core
adc_valid ever seen: 1
corr   : 0
```

**What this establishes:** the vendor receive core and our core are in one
bitstream on real silicon; ADI's core runs and issues sample-valid strobes; our
correlator is wired to them and counts them on the recovered bus clock.

**What it does not:** `corr` is zero because the samples are zero. The AD9361
bus pins are driven by an LFSR inside the fabric, not by an AD9361, and the
vendor core's formatting path evidently produces zeros for that input. A
non-zero correlation needs either real pins into the transceiver -- which needs
the pinout question answered -- or a test pattern injected further down the
core, past the input formatting.

That is the honest shape of it: **the integration is proven, the signal is
not.**

Log: `results/corr_in_rx_silicon.log`.
