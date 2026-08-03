# Removing the UNIMACRO blocker

## The blocker

Building ADI's HDL through yosys fails on `MULT_MACRO`, a Xilinx UNIMACRO.
Verified in the openXC7 container itself: the yosys share directory contains
**no UNIMACRO library and no file mentioning `MULT_MACRO`**. Yosys will not
elaborate it and there is nothing to point it at.

It is reached from `ad_iqcor` and the `ad_dds_*` modules, which are unavoidable
generic dependencies of `axi_ad9361`, so this is not a corner that can be
avoided by leaving a feature out.

## Why it turned out to be small

`MULT_MACRO` appears in **exactly one file in the entire ADI tree** --
`library/xilinx/common/ad_mul.v` -- and the instantiation pins the two
parameters that carry all the difficult behaviour:

```verilog
MULT_MACRO #(.LATENCY(3), .WIDTH_A(A_DATA_WIDTH), .WIDTH_B(B_DATA_WIDTH))
  i_mult_macro (.CE(1'b1), .RST(1'b0), .CLK(clk),
                .A(data_a), .B(data_b), .P(data_p));
```

`CE` is tied high, `RST` is tied low. Every documented trap in reimplementing
this macro -- what `RST` clears and whether it is synchronous, how `CE` gates
individual pipeline stages, the combinational special case at `LATENCY(0)` --
is unreachable at this call site. What remains is a signed multiply with three
pipeline registers.

The latency is corroborated by ADI's own code rather than taken on trust:
`ad_mul` carries a three-deep delay line for its side channel
(`p1_ddata -> p2_ddata -> ddata_out`), which is only correct if the multiplier
is three deep as well.

## The replacement, and how it was checked

`ad_mul_open.v` reproduces the pipeline literally -- input registers, then the
M register, then the P register -- rather than merely matching the final value,
so intermediate stages line up too. `A` and `B` are cast with `$signed`
explicitly, because `ad_mul` declares its ports as plain vectors while
`MULT_MACRO` treats them as signed (UG953), and getting that wrong would
corrupt the datapath silently rather than loudly.

**Simulation**, `ad_mul_open_tb.v`, Icarus Verilog 12.0:

```
ad_mul_open: 4000 checked, 0 errors
```

Corners first -- `0x0`, `AMAX x AMAX`, `AMIN x AMIN`, `AMIN x AMAX`, `-1 x 1`,
`-1 x -1` -- then 4000 pseudo-random pairs from a fixed LFSR seed, so the run
reproduces. The reference is an independent three-stage delay of `a * b`, and
the check is on every cycle, which tests the latency as strictly as the
arithmetic: a two- or four-deep implementation fails immediately.

**Synthesis**, yosys 0.62, `synth_xilinx`:

```
1 DSP48E1, 16 SRL16E, 1 BUFG
Found and reported 0 problems.
```

One DSP48E1 -- the same resource `MULT_MACRO` targets.

**And the match is structural, not merely arithmetic.** Reading back the
netlist yosys produced:

```
AREG = 1   BREG = 1   MREG = 1   PREG = 1
FDRE in fabric: 0
```

That is exactly the register configuration `MULT_MACRO` sets for `LATENCY(3)`:
all four pipeline registers absorbed **inside** the DSP48E1, none stranded in
the fabric. This is the part a naive replacement gets wrong -- writing the
pipeline as a single behavioural delay leaves the registers outside, which
measures as `1 DSP + 36 FDRE` with `AREG = BREG = 0`, costs fabric, and moves
the timing. Writing it as separate A/B, M and P stages, in that order, lets the
tool fold them where the macro would have put them.

The 16 `SRL16E` are the `ddata` side channel, which ADI's original carries too.

The blocker is removed at the cost of one file.

## A point that must not be muddled

This replacement **uses a multiplier**, and that is correct. The
no-multipliers claim in this project is about *our correlator*, whose weights
are ternary. ADI's IQ correction and DDS multiply arbitrary values by arbitrary
coefficients; there is nothing ternary about them and no reason to pretend
otherwise. Porting their multiplier faithfully is what makes it possible to put
our multiplier-free core into the same datapath.

## What this does not settle

One file elaborates. `axi_ad9361` as a whole has not been run through yosys,
and the remaining known obstacles are unchanged: `IBUFG`/`IBUFGDS` are unknown
to both nextpnr forks, `BUFIO` has no bels, `BUFR` **silently emits an
undivided clock** because openXC7 hardcodes `BUFR_DIVIDE.BYPASS`, and
`MMCME2_ADV` fails on a prjxray bit collision. Substitutions exist for all of
them; none has been tried in anger.

## Three properties of the original that do not bite here, recorded anyway

An independent reading of the real `MULT_MACRO` source turned up behaviour that
would matter at a different call site. None of it applies to ADI's, but a future
port to some other ADI-adjacent code might hit it:

- **`LATENCY(0)` is not combinational.** The DSP48E1's `OPMODEREG` defaults to
  1, so a `LATENCY(0)` macro still has a control register in the path and does
  not behave as a plain `assign`. UG479 v1.10 p.26 lists the default; p.29 says
  that register is enabled by `CECTRL` and reset by `RSTCTRL`.
- **`RST` is synchronous, active-High, has priority over `CE`, and flushes the
  whole slice** -- ten reset pins, not just the output register. A replacement
  that resets only `P` would diverge on the first reset.
- **`WIDTH_A > 25` leaves the DSP's `A_IN` undriven and `P` all-x**, silently,
  rather than erroring. ADI uses 17, well inside the limit.

`ad_mul` ties `CE` high and `RST` low and asks for `LATENCY(3)` and 17-bit
operands, so all three are unreachable at this one call site. They are written
down because "unreachable here" is a different statement from "does not exist",
and the first one expires the moment someone reuses this file.
