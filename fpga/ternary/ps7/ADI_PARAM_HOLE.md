# A parameter value that silently removes the receive datapath

**Severity: high.** `FPGA_TECHNOLOGY = 0` builds cleanly, loads, runs, reports
its channel enabled, produces valid strobes at the right rate -- and delivers
nothing but zeros, because the wires that should carry the samples have no
driver at all.

This is written up separately from `UPSTREAM_BUGS.md` because the defect is in
Analog Devices' HDL rather than in openXC7, and because it cost more than either
of those two put together.

## What happened

The correlator-in-datapath image read back, on silicon:

```
adc_enable_i0 : 0
corr          : 0
```

The obvious reading is that the vendor core's receive channel was switched off,
and that reading was correct as far as it went: nothing had ever written the
core's control registers, because the AXI slave port was tied to an LFSR. So the
port was connected to the PS properly (`axi3_to_lite.v`), and from Linux:

```
0x40000000 = 0x000A0300     ADI version, predicted from up_adc_common.v:134
0x40000008 <- 0xDEADBEEF -> 0xDEADBEEF     scratch tracks writes
0x40000040 <- 0x3                          core out of reset
0x40000400 <- 0x1                          channel 0 enabled
adc_enable_i0 : 1                          <-- now on
corr          : 0                          <-- still nothing
any_nonzero   : 0                          <-- not one non-zero sample, ever
```

Enabling the channel changed the enable bit and nothing else. `any_nonzero` is
the useful signal here: it distinguishes "the data is zero" from "there is no
data", and it says the samples were *always* zero, not sometimes.

## The cause

`library/xilinx/common/ad_data_in.v` builds the receive path from three
`generate` blocks in series: input buffer, delay, DDR capture register. Each
tests `FPGA_TECHNOLOGY`, and **none of them has a default branch**.

```verilog
// bypass IDELAY
generate if (IODELAY_ENABLE == 0) begin
  assign rx_data_idelay_s = rx_data_ibuf_s;
end endgenerate

// idelay
generate if (FPGA_TECHNOLOGY == SEVEN_SERIES && IODELAY_ENABLE == 1) begin
  IDELAYE2 ...
end endgenerate

// iddr
if (FPGA_TECHNOLOGY == ULTRASCALE || FPGA_TECHNOLOGY == ULTRASCALE_PLUS) begin
  IDDRE1 ...
end
if (FPGA_TECHNOLOGY == SEVEN_SERIES) begin
  IDDR ...
end
```

With `FPGA_TECHNOLOGY = 0` and `IODELAY_ENABLE` left at its default of 1:

- the bypass does not elaborate, because `IODELAY_ENABLE != 0`;
- the `IDELAYE2` does not elaborate, because the technology is not 7-series;
- the `IDDR` does not elaborate, for the same reason.

`rx_data_idelay_s`, `rx_data_p` and `rx_data_n` are therefore driven by nothing.
Twelve data bits and the frame bit, times two phases, all undriven, all read as
zero.

`FPGA_TECHNOLOGY = 0` is not a valid value for this core. There is no code path
that implements it. Nothing says so -- not the parameter declaration, not a
comment, not an elaboration-time error.

## Why it was chosen in the first place

Deliberately, and for a reason that was sound at the time: with
`FPGA_TECHNOLOGY = 0` the `IDELAYCTRL` is not instantiated, and openXC7 rejects
an orphaned `IDELAYCTRL`. It also removed an `IDELAYE2` whose `IDATAIN` could
not be driven in a design with no package pins. The value was picked to make the
build succeed, and it did -- which is exactly the trap. **The parameter that made
the tool stop complaining was also the parameter that emptied the datapath.**

## The evidence was in the log the whole time

yosys said so, ninety-nine times:

```
Warning: Wire ps7_ad9361_axi.\u_rx.genblk1.i_dev_if.rx_data_0_s [11]
         is used but has no driver.
```

Every one of those lines was in `syn.log` from the first build onward, and I had
not read them. A synthesis warning that names an undriven wire in a datapath is
not noise. This is the second time in this project that the right answer was
sitting in a log file while a hypothesis was being tested on hardware; the first
was the `is_string` backtrace in `UPSTREAM_BUGS.md`.

Counting them is now part of the build check:

| build | `has no driver` warnings | undriven `rx_data_0_s` bits | IDDR cells |
|---|---|---|---|
| `FPGA_TECHNOLOGY(0)`, defaults | 99 | 12 | 0 |
| `+ IODELAY_ENABLE(0)`, `NO_IBUF(1)` | 29 | 12 | 0 |
| `+ FPGA_TECHNOLOGY(1)` | **0** | **0** | **13** |

Thirteen: twelve data bits and the frame.

## The fix

Two small patches, both preserving the original behaviour at default parameters
(`adi-rx-datapath.patch`):

1. `ad_data_in.v` gains `NO_IBUF` (default `0`). When set, the input buffer is
   replaced by a straight assignment. This is a harness accommodation, not a
   functional change: with no package pin behind the input there is nothing for
   an `IBUF` to buffer, and an explicitly instantiated one driven from fabric is
   not placeable.

2. `axi_ad9361_cmos_if.v` passes `IODELAY_ENABLE(0)` and `NO_IBUF(1)` to the two
   receive `ad_data_in` instances.

With the delay and the buffer switched off *by parameter* rather than by
starving the technology test, `FPGA_TECHNOLOGY` can be declared truthfully as
`SEVEN_SERIES`. The `IDELAYE2` still stays out, because its generate requires
`IODELAY_ENABLE == 1`; the `IDELAYCTRL` still stays out, because
`IODELAY_CTRL_ENABLED = IODELAY_ENABLE & IODELAY_CTRL` is zero. Both are
excluded for the reason they should be excluded, and the `IDDR` appears.

## What to report upstream

Not the patch -- the hole. The useful request is:

> `ad_data_in.v` has three technology-gated `generate` chains with no default
> branch. A value of `FPGA_TECHNOLOGY` outside `{1, 2, 3}` produces a module
> whose outputs are undriven, silently. Please add an elaboration-time error --
> `initial if (FPGA_TECHNOLOGY != ...) $fatal` or a `generate ... else` that
> instantiates nothing but fails a bounds check -- so that an unsupported
> technology is rejected rather than yielding a design that builds, loads, runs
> and returns zeros.

The same pattern appears in `ad_data_out.v` and `ad_mmcm_drp.v`, which declare
the same `localparam` set. They are worth the same audit.

## The general lesson, which is not about Xilinx

A parameter that selects between implementations, with no default and no bounds
check, is a silent failure waiting for the first user who passes an unlisted
value. The failure mode is the worst available: not a build error, not a
run-time error, but plausible-looking zeros. Anything downstream that measures
signal power, correlates, or thresholds will simply report "nothing detected"
and be believed.

For a radar receive chain that is precisely the failure you must never have, and
it is the reason `any_nonzero` exists as a hardware register in this design
rather than as an inference from the correlation result. A detector that reports
"no target" and a detector that is disconnected look identical from the outside
unless something is watching the raw samples.
