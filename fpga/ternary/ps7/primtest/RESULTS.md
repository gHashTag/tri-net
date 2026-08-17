# Can the open flow build radio infrastructure? Measured, 2026-08-03

The question that gates everything: putting the correlator into the live AD9361
datapath needs hard I/O and clocking primitives, and **this repository contains
none of them**. Verified: zero `IBUFDS`, `ISERDESE2`, `OSERDESE2`, `IDELAYE2`,
`MMCME2`, `PLLE2` instances in any `.v`. Every "AD9361" hit in the RTL is a
comment, and the only design ever loaded into silicon declares no ports at all.

So the honest position was: "fully open flow" and "our RTL in the live radio
path" might be mutually exclusive on this device, and nobody had checked.

Now somebody has. One minimal design per primitive, each pushed through the
whole flow — yosys, nextpnr-xilinx, fasm2frames, xc7frames2bit — on
`xc7z020clg400-1` with real package pins from `package_pins.csv` (bank 35).

| Primitive | yosys | nextpnr | fasm2frames | .bit | verdict |
|---|---|---|---|---|---|
| `IBUFDS` | OK | OK, 665 lines | OK | 4 045 673 B | **passes** |
| `PLLE2_BASE` | OK | OK, 783 lines | OK | 4 045 672 B | **passes** |
| `OSERDESE2` | OK | OK, 137 lines | OK | 4 045 674 B | **passes** |
| `ISERDESE2` | OK | OK, 221 lines | OK | 4 045 674 B | **passes** |
| `MMCME2_BASE` | OK | OK, 1050 lines | **fails** | — | see below |

**Four of five pass end to end, and the one failure has a working substitute.**

## The differential buffer was supposed to be the blocker. It is not.

`IBUFDS` was the primitive cited as the open issue in openXC7 and therefore the
reason the radio path might be unreachable. It places, routes, assembles and
produces a loadable bitstream. The concern is retired.

## The MMCM failure, precisely

```
prjxray.fasm_assembler.FasmInconsistentBits:
FASM line "CMT_TOP_L_LOWER_B_X178Y113.CMT_LR_LOWER_B_MMCM_CLKFBIN.CMT_L_LOWER_B_CLK_IN3_INT"
wanted to clear bit (9244, 31, 23)
but was set by FASM line "CMT_TOP_L_LOWER_B_X178Y113.CMT_LR_LOWER_B_MMCM_CLKIN2.CMT_L_LOWER_B_CLK_IN2_INT"
```

nextpnr emits two CMT clock-mux features whose bit encodings collide on a single
bit. This is a defect at the nextpnr-xilinx / prjxray-db boundary — either the
database assigns that bit to both muxes wrongly, or the router picks a feedback
path it should not. It is reproducible, it has an exact coordinate, and it is
the kind of thing that can be filed upstream rather than worked around blindly.

Note the first error seen was an `ImportError ... circular import` from the
`fasm` package. That is a red herring thrown while formatting the traceback; run
`fasm2frames` directly and the real exception above appears.

**Workaround: use `PLLE2_BASE`.** It passes cleanly and covers most of what a
radio datapath asks a clock manager to do. `MMCME2` adds fractional divide and
finer phase shift; if the design genuinely needs those, the bit conflict has to
be fixed first.

## Practical gotcha, cost two runs to find

nextpnr cannot route a constant to a dedicated site wire. Tying `DDLY`,
`SHIFTIN1`, `SHIFTIN2` or `CLKDIVP` to `1'b0` produces:

```
ERROR: Unrouteable $PACKER_GND_NET sink u_is.DDLY (SITEWIRE/ILOGIC_X1Y142/DDLY)
```

Leave them unconnected instead. Vivado tolerates the tie-off; this flow does not.

Also: the XDC parser does not expand `[get_ports {q[*]}]`. Constrain each bit
explicitly or every port after the first reports "has no IOSTANDARD property".

## What this changes

The largest single risk to putting the correlator in the live radio path was
that the open toolchain could not express the radio at all. It can. What remains
is ordinary integration work plus one upstream bug with a substitute available
today — a different and much smaller problem than the one we thought we had.

Reproduce: `docker run --platform linux/amd64 -v "$PWD":/work -w /work
regymm/openxc7 bash /work/probe2.sh` (and `probe4.sh`, `probe5.sh`).
