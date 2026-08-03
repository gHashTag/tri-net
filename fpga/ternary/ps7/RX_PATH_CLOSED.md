# The receive path, end to end, with data actually moving

Our multiplierless 63-tap despreader now sits inside Analog Devices' AD9361
receive datapath on real silicon, fed by data that has traversed the vendor's
capture stage, frame delineation and channel logic, with the core's control
registers driven from Linux over a real AXI bus.

Measured on the Pluto's XC7Z020, 2026-08-03:

```
bridge alive     : 0x5A5A47C0
ADI version      : 0x000A0300      predicted from up_adc_common.v:134 first
adc_enable_i0    : 1
any_nonzero      : 1
last sample      : 0x563
corr / count     : 0x00FFE039 / 0x12    (-8135)
                   0x00FFFA61 / 0x6C    (-1439)
                   0x00FFF169 / 0xBA    (-3735)
                   0x00FFF79D / 0x0C    (-2147)
                   0x00FFF7C1 / 0x1E    (-2111)
                   0x00FFFBE1 / 0x07    (-1055)
```

Payload SHA-256 of the bitstream that produced this:
`4636d947a611fc37add4c09fa90c3915365bc1e679510fac644c131facf9f8d0`

## What had to be fixed, in the order the faults were peeled back

Four separate causes, each of which fully explained the symptom "corr = 0" and
each of which was, on its own, insufficient.

**1. The AXI slave port was tied to noise.** The core's control registers were
driven by the same LFSR as its data pins, so nothing had ever enabled the
receive channel. `adc_enable_i0` read back 0. Fixed by connecting the port to
the PS through `axi3_to_lite.v` -- a minimal AXI3-to-AXI4-Lite bridge, since
this flow has no vendor interconnect.

The bridge was simulated before it was built: single beats, four-beat bursts in
both directions, ID echo, `RLAST` placement, and a slave that never answers.
That last case is the one that matters, because a bridge that stalls on an
unresponsive slave hangs the CPU and the only recovery is a power cycle. It
completes the transaction itself with `SLVERR` after 1024 cycles instead.

Once connected, the register file behaved exactly as the source said it would:
version `0x000A0300` at offset 0, and the scratch register at offset 8 returning
`0xDEADBEEF` and then `0x12345678`. Both predictions were written down before
the board was powered.

**2. `FPGA_TECHNOLOGY = 0` removed the datapath.** Enabling the channel changed
the enable bit and nothing else. The cause is in ADI's `ad_data_in.v`: three
technology-gated `generate` chains with no default branch, so an unlisted
technology value yields a module whose outputs are undriven. Written up in full
in `ADI_PARAM_HOLE.md`; the evidence was ninety-nine `has no driver` warnings
sitting unread in the synthesis log.

**3. The IOB capture register cannot exist in a pinless design.** With the
technology declared truthfully, the `IDDR` appeared -- and nextpnr rejected it:

```
ERROR: IDDR '...i_rx_data_iddr' has D input connected to illegal cell type FDSE
```

This is not a tool defect. An ILOGIC site's `D` input is reachable only from the
pad, so an `IDDR` fed from fabric is genuinely unplaceable. A design with no
package pins cannot exercise the vendor's capture primitive, and pretending
otherwise would be the kind of claim this project exists to avoid making.

So the boundary is drawn explicitly instead. `ad_data_in.v` gains a `PINLESS`
parameter, default 0, that replaces the two IOB primitives with fabric
equivalents sampling the same two clock edges. **A design built with
`PINLESS = 1` proves nothing about the IOB capture stage.** It proves the
datapath from the capture register onward. That limit is stated in the parameter
comment, in the patch, and here.

**4. An LFSR is not a bus.** With the datapath complete, the sample count froze
at exactly zero -- and a frozen count looks identical whether the clock is dead
or the protocol never validates. A free-running `l_clk` counter, readable over
AXI, separated the two in one reading: the clock was fine.

The remaining fault was the stimulus. `rx_clk_in` was an LFSR bit, which holds
its value for runs of several cycles and has no duty cycle; `rx_frame_in` was
another. Both were replaced with what the protocol requires: a clean divide-by-
two clock, and a frame that alternates at half the bus rate.

Then the delineation logic itself, `axi_ad9361_cmos_if.v:225`. With
`rx_r1_mode = 0` and the frame held low, the case selected is `3'b000`, which
writes `adc_data_p[47:24]` and leaves `[23:0]` -- where channel I0 lives --
holding its reset value. **Continuous valid strobes with permanently zero I0**,
which is precisely what the previous build measured. Data reaches I0 only when
the frame alternates: one bus period writes the low half without validating, the
next latches and asserts valid.

## A prediction that missed, and what it bought

The frame observer was predicted to read `0x9` -- codes `2'b11` and `2'b00` in
turn. It read `0x7`: codes `00`, `01` and `10`. The stimulus phase is not the one
that was designed, and the alternation that carries the data is the *other* legal
pair, `3'b001` writing the low half and `3'b010` latching it.

The register was added precisely so a wrong phase would be visible rather than
silently absorbed, and that is what happened. It is worth noting that the
measurement still succeeded: two distinct frame alternations satisfy this
protocol, and the stimulus happened to land on the one that was not intended.

## What is proven and what is not

Proven, on silicon:

- our correlator runs inside ADI's receive datapath, clocked on the recovered
  bus clock, fed by `adc_data_i0` / `adc_valid_i0`;
- the vendor core is controlled from userspace over AXI, exactly as Linux would
  control it, with register values predicted from source before measurement;
- the samples reaching the correlator are non-zero and traceable to the
  stimulus, and the correlation output is non-zero, signed, and varies with the
  data.

Not proven, and not claimed:

- **bit-exactness against the software model in this configuration.** The 256/256
  agreement at 8 and 63 taps in `ATSPEED.md` stands, but it was measured with
  samples pushed directly into the correlator. Predicting the exact value here
  requires modelling the vendor path's sample sequence, including the frame
  phase above. That is the next piece of work, and it is the one that would turn
  "non-zero and plausible" into "correct".
- **the IOB capture stage**, for the structural reason given above. It needs a
  design with real pins, which needs the per-pin direction map that
  `PINOUT.md` records as still unresolved.
- **timing at the real AD9361 bus rate.** `l_clk` here is 25 MHz from a fabric
  divider, not a recovered 61.44 MHz LVDS clock.

## Files

| File | What it is |
|---|---|
| `axi3_to_lite.v` | AXI3 to AXI4-Lite bridge, bursts iterated, timeout to `SLVERR` |
| `axi3_to_lite_tb.v` | its testbench, including the never-answering slave |
| `ps7_ad9361_axi.v` | top level: PS7, bridge, `axi_ad9361`, correlator, status registers |
| `adi-rx-datapath.patch` | `PINLESS` and `IODELAY_ENABLE(0)` against ADI's HDL |
| `ADI_PARAM_HOLE.md` | the `FPGA_TECHNOLOGY = 0` defect, written for upstream |

## Register map, from Linux

```
0x40000000  ADI version      0x000A0300
0x40000008  scratch          read/write, the bus self-test
0x40000040  reset            write 0x3 to release core and MMCM
0x40000400  channel 0        bit 0 enables the receive channel
0x40010000  bridge magic     0x5A5A47C0
0x40010004  correlator out   24-bit signed
0x40010008  sample count
0x4001000C  state            [0] valid seen [1] enable [2] r1_mode [3] any non-zero
0x40010010  last sample
0x40010014  l_clk heartbeat  free-running, proves the clock lives
0x40010018  frame codes seen bit n set = frame code n occurred
```
