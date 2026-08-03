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
  data;
- **bit-exactness against the software model**, closed in the following cycle --
  see the second half of this file.

Not proven, and not claimed:

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


---

# Bit-exact, inside the datapath

Added 2026-08-03, closing the one claim the section above left open.

A snapshot of a free-running stream read over AXI is a number that can be
admired but not checked, so the capture was made deterministic. Writing 1 to
`0x40010020` resets the correlator, reloads its taps, records exactly 64 input
samples and 64 outputs into two fabric memories, and freezes. The result is then
a function of the stimulus.

`verify_in_datapath.py` re-derives every output from the inputs. The model is
written from `tern_corr_pn_tree.v` rather than from intent, and the point that
matters is the alignment: `m_data <= corr` is registered while `corr` is
combinational over the shift register *before* the current sample enters it, so
the value emitted alongside the j-th valid sample is the correlation over
samples j-1 .. j-63, and the first output is necessarily zero. That is the same
off-by-one `FIRST_LOAD.md` records getting wrong once already.

## Result

Six captures, 384 sample-output pairs, every one matching:

| capture | input range | negative inputs | output range | verdict |
|---|---|---|---|---|
| ramp, unsigned | 183 .. 435 | 0/64 | -187 .. 187 | 64/64 bit-exact |
| round 1 | 699 .. 951 | 0/64 | -703 .. 703 | 64/64 bit-exact |
| round 2 | -809 .. -557 | **64/64** | -817 .. 817 | 64/64 bit-exact |
| round 3 | -841 .. -589 | **64/64** | -849 .. 849 | 64/64 bit-exact |
| round 4 | 1111 .. 1363 | 0/64 | -1115 .. 1115 | 64/64 bit-exact |
| round 5 | 959 .. 1211 | 0/64 | -963 .. 963 | 64/64 bit-exact |

Negative inputs were reached without rebuilding anything, by enabling the
vendor's own data-format register: `0x40000400 = 0x51` sets sign extension
(bit 6) and the format block (bit 4) alongside the channel enable (bit 0), so a
12-bit sample with bit 11 set arrives as a negative 16-bit value. Two of the
five rounds landed entirely in that half, which is why signed arithmetic is
covered in place rather than only in the bench.

## The comparison can fail

A match is worth what the test's ability to fail is worth, so that was measured
too. Against the round-one capture:

| perturbation | outcome |
|---|---|
| baseline | match |
| tap 0 sign flipped | mismatch |
| tap 31 sign flipped | mismatch |
| tap 62 sign flipped | mismatch |
| alignment shifted by one sample | mismatch |
| one input sample changed by one LSB | mismatch |
| first two input samples swapped | mismatch |

The model itself is cross-checked against a second, independently formulated
implementation -- a shift-register simulation against a padded-history slice --
over 200 random 64-sample sequences.

## What this does and does not extend

It extends the 256/256 result in `ATSPEED.md` from "the correlator is correct
when samples are pushed into it" to "the correlator is correct on samples
delivered by ADI's capture, frame delineation and channel logic, under control
from Linux over a real AXI bus".

It does not extend to the IOB capture stage, which `PINLESS = 1` removes by
construction, nor to the real bus rate. Those limits are unchanged.

## A stale log read as a fresh result

Worth recording because it nearly published a wrong finding. Two capture runs
reported `BUSERROR` on every read. The cause was not the hardware: `/tmp` on
this board is tmpfs and the reboot at the end of each run wipes it, taking the
runner script with it, so the second run never executed at all -- and
`/mnt/jffs2`, which persists, still held the first run's log. The failing output
being read was several minutes old.

The fix is procedural: write the script and copy the bitstream in the same
session as the run, and delete the log before starting so a stale one cannot be
mistaken for a new one.


---

# Full bus range, and a reproducibility question answered no

Added 2026-08-03.

The previous section's captures ran on a counter: a ramp of step 4 spanning 252
of the bus's 4096 codes, never changing sign. That proves the plumbing and
leaves the adder tree's carries untested, so the stimulus is now selectable from
AXI at `0x40010028` -- bit 0 picks a maximal-length 12-bit LFSR over the counter,
bit 1 reloads its seed on arming.

With the core's sign-extension bit set, the LFSR covers the full signed range of
the bus and changes sign repeatedly inside the 63-tap window, which is what
makes carries propagate through the whole reduction.

| capture | input range | distinct | sign changes | output range | verdict |
|---|---|---|---|---|---|
| `lfsr1` | -2003 .. 1955 | 64/64 | 41/63 | -14960 .. 14719 | 64/64 bit-exact |
| `lfsr2` | -2045 .. 2031 | 64/64 | 32/63 | -21239 .. 17020 | 64/64 bit-exact |
| `lfsr3` | -1894 .. 1976 | 64/64 | 33/63 | -16458 .. 14841 | 64/64 bit-exact |
| `seed1` | -1941 .. 1762 | 64/64 | 39/63 | -20004 .. 19561 | 64/64 bit-exact |
| `seed2` | -2009 .. 2032 | 64/64 | 23/63 | -10394 ..  9383 | 64/64 bit-exact |

The bus carries 12 bits, so -2048 .. 2047 is the range, and -2045 .. 2031 is
effectively all of it. Output magnitude reaches 21 239 against 187 before --
a hundredfold wider excursion through the same adder tree.

Running total across both sections: **eleven captures, 704 sample-output pairs,
every one bit-exact.**

## Reproducible? No -- and that is worth knowing

Two captures with the LFSR reseeded on arming should have been identical. They
were not: **all 64 input samples differ.**

The stimulus itself is deterministic -- it reloads the same seed -- so what
varies is the phase between the arm pulse and the vendor's frame. Arming comes
from a software register write at an arbitrary moment, the capture start is
synchronised into the bus-clock domain, and where that lands within the frame
cycle decides which slice of the LFSR sequence reaches the correlator.

This does not weaken anything above. The model is fed the *measured* inputs, so
a shifted window changes which samples are checked, not whether the check is
valid. What it does cost is a golden vector: a fixed input array that a
regression could compare against byte for byte, on any board, at any time. That
needs the capture to start on a known frame boundary rather than whenever
software happens to ask.

The question was posed before the measurement precisely because the answer was
not obvious, and guessing "yes" would have been the comfortable error.

## The case still missing

None of these captures approaches the accumulator's real limit. The maximum is
63 x 2047 = 128 961, reached when the input *is* the tap sequence scaled --
which is exactly the matched-filter peak a despreader exists to produce. Driving
the stimulus with the PN sequence itself would test the accumulator's full
magnitude and demonstrate the function rather than only the arithmetic.


---

# The matched-filter peak, and reproducibility achieved

Added 2026-08-03, taking the two items the previous section left open.

## The peak

The accumulator's true maximum is 63 x 2047 = **128 961**, reached when the
input carries +2047 wherever a tap is +1 and -2047 wherever it is -1. That is
not an arithmetic curiosity: it *is* the despreading operation, so hitting it
tests the full magnitude and demonstrates the function in one capture.

A third stimulus mode emits that sequence, and one detail in it is not
cosmetic. After 63 samples `xr[i]` holds the sample from `i` steps ago, so
`xr[i] = in[j-1-i]`; for every term to add rather than cancel, the chip emitted
at step `k` must be `tp[62-k]` -- **the tap sequence reversed**. Emitted forward,
the result is the autocorrelation at lag 62 instead.

The first attempt captured 64 samples and read 75 739 = **37 x 2047**, the
signature of a shifted window. With a 63-deep shift register and a 64-sample
capture, only the very last output has a full window, so the peak has to land on
exactly that one sample -- which requires the stimulus phase to survive a
clock-domain crossing, and it did not.

The fix is general rather than a phase adjustment: **capture 128 samples**. The
first 64 warm the register, every output in the second half has a full window,
and a 63-periodic input must therefore put the peak in one of them at any phase.
Checked over all 63 phases in software before the build: reachable at every one.

Measured:

```
pn1: outputs 63..127  65/65 bit-exact   |max| 128961 = 63 x 2047, at index 68
pn2: outputs 63..127  65/65 bit-exact   |max| 128961 = 63 x 2047, at index 68
lf1: outputs 63..127  65/65 bit-exact   |max|  30303
```

## Reproducibility

`pn1` and `pn2` are **identical in all 256 words** -- every input sample and
every output. The previous cycle's answer to "are two reseeded captures the
same?" was no, with all 64 samples differing. Arming now waits for a known frame
code before starting, and the stimulus index resets at that instant, so the
capture no longer depends on when software happened to write the register.

That is a golden vector: a fixed array a regression can compare byte for byte.

The alignment is not unconditional. Of the three captures taken with an earlier
build that reset the sequence at the frame match but before the taps had
reloaded, two agreed and the third did not. Waiting for `taps_done` as well as
the frame code is what made it hold.

## An assumption the change invalidated

The model asserts the shift register starts cleared, which was true while the
capture began with the correlator in reset. A frame-aligned start deliberately
begins *after* the reset lifts, so the register is already warm -- `out[0]` came
back as -2047, not 0 -- and the first 63 outputs depend on samples that were
never recorded.

Reported honestly rather than tuned away: those 63 outputs are **not checked**,
because checking them would mean comparing against data that does not exist.
Outputs from index 63 onward depend only on captured inputs and are checked in
full. `verify_in_datapath.py` now detects the warm start and narrows its window
accordingly instead of reporting a mismatch it cannot resolve.

## Running total

| cycle | captures | verified pairs |
|---|---|---|
| bit-exactness | 6 | 384 |
| full bus range | 5 | 320 |
| matched PN, 64-deep | 5 | 320 |
| matched PN, 128-deep | 3 | 195 |
| **total** | **19** | **1219** |

Every one exact.


---

# Real pins: built, loaded, and the radio is silent

Added 2026-08-03.

`ps7_ad9361_real.v` is the first design here with real package pins. Every port
is an input -- the fourteen bank-34 pins `pin_directions.py` identifies as
single-ended inputs in the vendor bitstream -- and `PINLESS` is 0, so the
vendor's own `IBUF` and `IDDR` are instantiated. Fourteen input buffers and
thirteen DDR capture registers: the IOB stage a pinless harness cannot exercise
by construction, and which nextpnr rejected when fed from fabric.

It places, routes, builds and loads. The classifier applied to our own bitstream
reports **14 inputs and 0 outputs**, which is both a round trip against a pinout
that is known because it was written, and the safety argument for loading it: a
bitstream that configures no pin as an output cannot drive against another
driver.

On silicon:

```
state       : operating
bridge      : 0x5A5A47C0
heartbeat A : 0x00000000
heartbeat B : 0x00000000      <- unchanged
frame codes : 0x00000000
saw_valid   : 0
```

**The bus clock is not running.** The heartbeat is a free-running counter on
`l_clk`; zero on two reads two seconds apart means the pin is not toggling. That
is a clean negative, and it is the reading the counter exists to produce: it
separates "no clock" from "no data" without a hypothesis.

## The likely reason, stated as a hypothesis

The AD9361 gates its data clock on its own state machine, and that machine is
driven by the `ENABLE` and `TXNRX` pins -- which are **FPGA outputs** in the
vendor design. This bitstream drives no outputs at all, so those pins float, and
a floating `ENABLE` leaves the part in a state where it does not clock the bus.

Two ways forward, and they differ in risk:

- **Drive `ENABLE` ourselves.** No contention: those pins are outputs in the
  vendor design too, so the direction matches. It needs identifying which of the
  46 output sites they are, which the classifier does not yet do.
- **Configure the part over SPI to keep the receive chain running** regardless
  of the pins, then reload. This touches no pin directions at all.

The second is the safer first attempt, and it is testable in one reading with
the same heartbeat.

## A check that could not fail correctly

Four rounds were spent diagnosing a file transfer that had in fact succeeded.
The size probe was `busybox stat -c %s FILE || echo missing`; this busybox does
not implement `-c`, so `stat` failed, printed nothing, and the fallback reported
`missing` -- for a file that was present and complete at 4 045 564 bytes.

The fallback fired on *the checking program* failing, not on the condition it
was meant to check. That is the fourth error of this shape in the project:
a DRIVE/SLEW heuristic, segbits signatures with no positive bits, the bank-wide
`STEPDOWN` setting, and now this. Each concluded something from the absence of
evidence rather than from evidence.

`ls -la` reports the size on this busybox and is what the scripts use now.


---

# Measuring the pins instead of arguing about them

Added 2026-08-03.

The real-pin design loaded and read no clock. Rather than guess why, the next
build counts transitions on **every** one of the fourteen pins, sampled on the
PS clock over a window of 2^23 cycles. It assumes nothing about which pin is
clock, frame or data -- the previous cycle inferred "N18 is the clock" from the
pin being MRCC-capable, which is a property of the package, not a measurement.

Two controls run through the identical counting path, because a counter that
always reads zero is indistinguishable from a broken one:

| | counter | expected |
|---|---|---|
| bit 14 | fabric divide-by-two | must equal the window length |
| bit 15 | tied low | must stay zero |

## Result

```
bit  0 : 0          bit  8 : 0
bit  1 : 1          bit  9 : 1
bit  2 : 0          bit 10 : 0
bit  3 : 0          bit 11 : 0
bit  4 : 0          bit 12 : 0
bit  5 : 0          bit 13 : 0
bit  6 : 1          bit 14 : 0x00800000   <- control, = window length
bit  7 : 1          bit 15 : 0            <- control, tied low
```

The positive control counted **every** cycle of the window and the negative
control counted none, so the instrument works. Against that, four pins made
exactly one transition each in 8 388 608 cycles and the other ten made none.
One edge in a window that long is a power-up settle, not a signal.

**None of the fourteen pins carries anything** while this bitstream is loaded.

## Two false results the controls caught first

The first two builds of this monitor reported zero on all fourteen pins **and on
the positive control**, which is the signature of a broken instrument rather than
a quiet bus. Publishing the first would have been publishing nothing dressed as
something.

- **A sixteen-entry array, incremented sixteen ways per cycle and read with a
  computed index, is inferred as a memory.** One write port; fifteen of the
  sixteen increments silently dropped. Replaced with sixteen explicit counters
  in a generate block.
- **The read address collided with the capture memory.** `0x40010440` decodes to
  the `in_mem` region, so every read returned an unwritten capture slot. The
  counters live at `0x40010040`. The RTL had been correct for one build already.

## What this does and does not establish

It establishes that these pins are electrically quiet. It does **not** establish
that they are the wrong pins: the classifier's identification of them as inputs
in the vendor bitstream stands on a round trip, and the vendor design is not
running while ours is.

The hypothesis was that the AD9361's `RESETB` floats under our bitstream. It was
tested and the answer turned out to be broader than the question. See below.


---

# Why the radio cannot answer us, structurally

Added 2026-08-03. This is the answer to the whole "no data" line of enquiry, and
it is not about pin identification.

## The measurement

An AD9361 register read over SPI, before and after loading our bitstream. The
prediction was written first: register `0x037` is the product ID and reads
`0x0A` on a working part.

```
vendor design running          our bitstream loaded
  reg 0x37  = 0xA                reg 0x37  = 0x0
  reg 0x002 = 0x5C               reg 0x002 = 0x0
  reg 0x017 = 0x1A               reg 0x017 = 0x0
  reg 0x014 = 0x29               reg 0x014 = 0x0
  reg 0x3fd = 0xFF               reg 0x3fd = 0x0
```

Every register goes to zero. Not defaults -- zero, including `0x3fd` which reads
`0xFF` normally.

## The structural reason

ADI's own top level says it plainly. From `projects/pluto/system_top.v`:

```verilog
output          enable,
output          txnrx,
inout           gpio_resetb,
output          spi_csn,
output          spi_clk,
output          spi_mosi,
input           spi_miso,
```

**The entire control path to the AD9361 runs through the PL.** SPI chip select,
clock and MOSI are FPGA outputs; reset and the ENSM control pins are FPGA
outputs. The processor does not reach the radio except through whatever design
is loaded in the fabric.

Our bitstream drives no outputs at all -- deliberately, because that is what
makes it safe to load. So it breaks SPI, `RESETB`, `ENABLE` and `TXNRX` at the
same moment. All-zero register reads are exactly what a severed SPI bus gives,
with no need to invoke anything about the part's state.

(The pin numbers in that constraint file are for `xc7z010clg225`, a different
package -- but the *topology* is the property that matters, and it is a property
of the silicon design, not the package.)

## What this means for the goal

"Load our bitstream and expect the radio to keep streaming" was never going to
work, and no amount of pin identification would have fixed it. Reading the
receive bus requires a design that also:

- passes the PS SPI controller through to the radio's SPI pins,
- drives `gpio_resetb` to hold the part out of reset,
- drives `enable` and `txnrx` for the ENSM.

That is not a pin puzzle, it is the rest of the vendor's `system_top` -- and a
good part of it is already built here. `axi_ad9361` synthesises, places, routes,
loads and runs through the open flow; the correlator inside it is bit-exact over
1219 sample pairs; the AXI bridge reaches its registers from Linux. What is
missing is the control plane around it.

## A risk worth naming

With the SPI lines floating, the radio's chip-select is undriven, and stray
transitions could in principle write its configuration. Every load in this
directory is followed by a reboot, which reloads the vendor bitstream and
reconfigures the part from scratch, so nothing has been observed to persist. It
is still a reason to drive `spi_csn` high rather than leave it floating, the
moment this design has any outputs at all.


---

# How fast does it actually run, inside the datapath

Added 2026-08-03.

`ATSPEED.md` measured the standalone correlator's silicon Fmax at 83.3 MHz clean
against a tool estimate of 58.26 -- the tool understates, because nextpnr has no
sequential timing model. The open question was the same number *inside* ADI's
receive datapath, where the AD9361's real bus clock is 61.44 MHz.

`ps7_ad9361_rate.v` puts the simulated bus on **FCLK1** so the rate can be swept
from Linux by writing `FPGA1_CLK_CTRL` at `0xF8000180`, while the AXI bridge,
the status registers and the capture readback stay on FCLK0 at a fixed 50 MHz.
Sweeping the clock that carries the measurement would confound the two.

## The meter, and why its window size is the whole design

A divider write that did not take effect is indistinguishable from one that did,
so the design counts `l_clk` cycles over a fixed window of the 50 MHz clock.

The first version used a 2^20 window and a 16-bit difference. At the top of the
sweep that counts 1.3 million cycles, so it overflows -- and **every
power-of-two divisor then reads exactly zero**. The meter would have agreed with
itself at every rate while measuring nothing. 2^16 keeps the count under 82 000.

Measured against values computed beforehand:

| divisor | FCLK1 | l_clk | expected | measured |
|---|---|---|---|---|
| 40 | 25.0 MHz | 12.50 MHz | 16384 | 16384 |
| 32 | 31.2 | 15.62 | 20480 | 20480 |
| 20 | 50.0 | 25.00 | 32768 | 32768 |
| 16 | 62.5 | 31.25 | 40960 | 40960 |
| 12 | 83.3 | 41.67 | 54613 | 54613 |
| 10 | 100.0 | 50.00 | 65536 | 65536 |
| 8 | 125.0 | 62.50 | 81920 | 81920 |

Every one exact. The clock really did move.

## Result

Captured inputs are the clean PN at **every** rate -- two distinct values,
+/-2047 -- so the stimulus and the vendor path deliver correctly throughout.
What varies is the agreement between the captured outputs and the model:

| l_clk | offset | mismatches |
|---|---|---|
| 12.50 MHz | 1 | **0 of 64** |
| 15.62 | 0 | **0** |
| 25.00 | 0 | **0** |
| 31.25 | 3 | 62 |
| 41.67 | 3 | 62 |
| 50.00 | 1 | **0** |
| 62.50 | 0 | 2 |

A constant one-sample offset is a property of *when the capture started*, not of
the arithmetic: the input and output streams are recorded by two counters, and
whether the first `m_valid` lands before or after the first `s_valid` depends on
the phase at capture start.

So: **bit-exact inside the vendor datapath at a 50 MHz bus clock**, against a
tool estimate of 37.75 MHz -- the tool understates by a third, consistent with
`ATSPEED.md`. At 62.5 MHz, above the AD9361's 61.44, 62 of 64 outputs agree.

## The two unexplained points, explained

31.25 and 41.67 MHz failed in a way no constant offset repaired, while 50 and
62.5 passed -- not the shape of a timing failure, which would worsen
monotonically. The cause turned out to be in the comparison, not the hardware,
and it was settled in simulation with no clock domains and no vendor logic
involved (`capture_duty_tb.v`):

| valid strobe | best lag | mismatches |
|---|---|---|
| sparse -- one valid, one gap | 1 | **0** |
| back-to-back -- valid every cycle | 2 | **0** |
| **mixed duty** | 1 | **32** |

`m_data` is registered from `corr` on **every** clock while `corr` advances only
on `s_valid`. So the value standing at the capture edge is the correlation over
`j-1 .. j-63` when the previous cycle was idle and over `j-2 .. j-64` when it
was another valid. **A strobe whose duty varies has no constant lag at all**,
and assuming one is what produced those two failures.

The fix is one bit per sample, recorded in hardware: whether the cycle before
that sample was also a valid. The model then uses the right lag for each sample
instead of a single lag for the capture. Nothing is searched for.

Claiming "runs at 62.5 MHz" on the strength of 62 of 64 would still be the kind
of rounding this file exists to avoid. The defensible claim remains 50 MHz
clean, and the sweep needs re-running with the per-sample bit before more can be
said.


---

# The whole experiment, offline

Added 2026-08-03, with the board unreachable.

`fullpath_tb.v` runs `ps7_ad9361_rate` exactly as built, with `sim_stubs.v`
standing in for the processor. The testbench performs the same AXI transactions
Linux performs through `devmem` -- release the core reset, enable channel 0 with
sign extension, select the matched PN stimulus, arm the capture -- and reads the
capture memories back over the same `axi3_to_lite` bridge. Nothing is bypassed.

```
bridge magic  : 5a5a47c0      (expect 5A5A47C0)
ADI version   : 000a0300      (expect 000A0300)

lclk 12.50 MHz  ->  0 mismatches of 63
lclk 25.00 MHz  ->  0 mismatches of 63
lclk 62.50 MHz  ->  0 mismatches of 63
```

The per-sample lag bit gives a clean result at every rate including 62.5 MHz,
where the hardware sweep had two mismatches under the constant-lag assumption.
The fix is confirmed before a board run is spent on it.

**What this does not show.** iverilog is functional, not timed. It cannot say
the design meets timing at 62.5 MHz on silicon; the measured claim there remains
50 MHz clean, from `ATSPEED.md`-style silicon measurement. What the simulation
settles is functional correctness and the correctness of the comparison.

## A real defect the simulator found that synthesis did not

Four of the top-level files declared the same eight wires twice --
`core_awready`, `core_wready` and the rest, once as a group and again
individually. yosys accepted it silently through every build in this directory.
iverilog rejects it, correctly.

Nothing was broken by it, but it is worth recording that a second front end
found a real error in sources that had passed synthesis, place, route and
silicon a dozen times. Two tools disagreeing is information; only one of them
was being consulted.

## The stubs, and one that would be wrong if the design changed

Most stubs are for primitives that appear in files iverilog elaborates but that
this configuration never instantiates -- empty bodies are correct precisely
because nothing reaches them.

`DSP48E1` is not one of those. It is instantiated in `ad_dcfilter`, which *is*
elaborated. Its product reaches the datapath only through `data_dcfilt`, and
that is selected only when `dcfilt_enb` is 1; this configuration leaves the DC
filter off, so the multiplier's result is discarded and a zeroed stub changes
nothing. **Enable the DC filter and this stub makes the simulation wrong.** It
says so in the file rather than passing quietly.


---

# The full sweep, offline, with the mechanism measured

Added 2026-08-03.

The seven rates of the hardware sweep, run in `fullpath_tb.v`, with the number
of back-to-back valid strobes counted rather than inferred:

| l_clk | back-to-back samples | per-sample lag | best constant lag |
|---|---|---|---|
| 12.50 MHz | 0 of 128 | **0 bad** | 0 bad |
| 15.62 | 0 | **0** | 0 |
| 25.00 | 0 | **0** | 0 |
| 31.25 | 0 | **0** | 0 |
| **41.67** | **52** | **0** | **26 bad** |
| 50.00 | 0 | **0** | 0 |
| **62.50** | **52** | **0** | **24 bad** |

The mechanism is now measured, not argued. At 41.67 and 62.5 MHz the vendor's
delineation emits valid on consecutive bus cycles for 52 of the 128 captured
samples, and a single constant lag cannot describe a capture whose lag changes
sample by sample. Everywhere the strobe is uniformly sparse, a constant lag
works and agrees with the per-sample one.

**The per-sample lag bit gives zero mismatches at every one of the seven rates,
including 62.5 MHz.**

## One difference from the hardware run, stated rather than smoothed

Hardware showed 31.25 MHz failing; simulation shows it clean, with a uniformly
sparse strobe. So the mechanism confirmed here accounts for 41.67 and 62.5 but
not for 31.25, and the residual could be a timing effect on silicon or a
difference in the phase the capture happened to start at -- `start_phase` is
recorded for exactly this reason and the values do vary across the sweep.

That point was then closed as far as simulation can close it -- see below.

What simulation still cannot say: whether the design meets *timing* at those
rates on silicon. The measured claim remains 50 MHz clean.


---

# The 31.25 MHz residual is not in this logic

Added 2026-08-03.

Hardware failed at 31.25 MHz; simulation did not. The obvious suspect was the
phase at which the capture happened to start, so the testbench arms the capture
at eight different delays relative to the readback clock and checks each.

```
arm delay 0 clk : idx 128, phase  5 | back-to-back 0 | per-sample 0 bad
arm delay 1 clk : idx 128, phase  5 | back-to-back 0 | per-sample 0 bad
arm delay 2 clk : idx 128, phase 13 | back-to-back 0 | per-sample 0 bad
arm delay 3 clk : idx 128, phase  5 | back-to-back 0 | per-sample 0 bad
arm delay 4 clk : idx 128, phase  5 | back-to-back 0 | per-sample 0 bad
arm delay 5 clk : idx 128, phase 13 | back-to-back 0 | per-sample 0 bad
arm delay 6 clk : idx 128, phase  5 | back-to-back 0 | per-sample 0 bad
arm delay 7 clk : idx 128, phase 13 | back-to-back 0 | per-sample 0 bad
```

The start phase really does vary -- the recorded value moves between 5 and 13
and the status word differs across delays, so the register is doing its job.
**No phase reproduces the failure.** Every capture completes, none shows a
back-to-back strobe, and all are bit-exact.

So the 41.67 and 62.5 MHz failures are explained and fixed, and the 31.25 MHz
one is not a property of this logic at any start alignment. It is attributable
to the silicon -- timing, or something outside the RTL -- and settling that
needs the board.

## A small instance of the same recurring error, in the testbench this time

The first run of the phase sweep printed a status of `00fed825` for every
delay, which is not a value that register can hold. The status was read into
`rdval` and then printed *after* 256 further reads had overwritten it, so the
number displayed was the last output word rather than the status. The
verification itself used the right data throughout, so no conclusion was
affected -- but a diagnostic that reports something other than what it claims is
the same family of error as the four already recorded in this directory, and
this one was in code written to avoid them.


---

# The real-pin design, verified

Added 2026-08-03.

`ps7_ad9361_real.v` has real package pins: fourteen inputs, the vendor's own
`IBUF` and `IDDR`, no outputs at all. It was built and loaded on silicon in an
earlier cycle and read nothing, because nothing was driving those pins -- and it
had never been checked functionally, because the IOB capture stage is exactly
what a pinless harness cannot instantiate.

`realpin_tb.v` drives the stimulus onto the ports, as the radio would.

```
bridge magic : 5a5a47c0        ADI version : 000a0300
l_clk heartbeat : 537 -> 1040  (running, from the port)
saw_valid 1    enable 1    any_nonzero 1
128 of 128 samples non-zero: 63 at +2047, 65 at -2047, 0 anything else
per-sample lag: 0 mismatches of 63
```

Every sample is one of the two PN chip values and nothing else, and the
correlator output matches the model on every fully-determined sample. **The
design is correct end to end when a signal arrives on its pins.** What was
missing on hardware was the signal, not the logic.

## The IDDR model, and what it is worth

`SAME_EDGE` presents both bits on the rising edge but they come from different
half cycles: `Q1` is the bit sampled on that rising edge, `Q2` the bit sampled
on the falling edge before it. That is what the model implements, and it is
worth being explicit that it is *my* model of the primitive, written from the
described behaviour rather than taken from a vendor library. A simulation is
only as good as its models, and this is the one place in this testbench where
that caveat bites.

It is corroborated by construction, though: the `PINLESS` substitute in
`ad_data_in.v` -- two fabric flops, one on each edge -- was written
independently and produces the same pairing, and the pinless design has been
bit-exact on silicon over 1219 sample pairs.

## An address that was wrong and looked plausible

The first run read `47c0 37f9 007d 000b ...` from the capture memory: nine
non-zero samples out of sixty-four and nothing resembling a PN chip. The cause
was a stale address map -- `0x40010100`/`0x40010200` from the 64-deep capture,
against a design that had moved to 128 entries at `0x40010400`/`0x40010800`.

`47c0` is the low half of the bridge magic, which is what makes this worth
recording: the wrong address returned *plausible-looking data* rather than an
error, and the first value was a recognisable constant from elsewhere in the
same register file. Reading a memory at the wrong offset is not a failure mode
that announces itself.


---

# One command for all five testbenches, and three vacuous controls

Added 2026-08-03.

`sim.py` builds and runs every testbench here and checks what each one claims:

```
[PASS] axi3_to_lite   single beats, bursts, ID echo, and a dead slave answered
[PASS] capture_lag    lag 1 clean, lag 0 rejected
[PASS] capture_duty   uniform strobes clean at lags 1 and 2; mixed duty 32 bad
[PASS] fullpath       rate sweep 7 checks all zero; phase sweep 8 all zero
[PASS] realpin        all samples are PN chips, capture bit-exact
```

Two of those checks are inverted on purpose. `capture_duty` **must** report
mismatches in its mixed-duty case -- that bench exists to show a constant-lag
comparison cannot work there, and a clean run would mean it had stopped testing
anything. `axi3_to_lite` must show its dead-slave case answered rather than
hung, because a bridge that stalls costs a power cycle.

## The part worth reading: three controls that proved nothing

A suite is worth what its ability to fail is worth, so a fault was injected and
the suite required to catch it. It took three attempts.

1. **Changed a module's default parameter.** `axi3_to_lite_tb.v` instantiates
   with `TIMEOUT(64)`, overriding the default. The edit could not reach the
   simulation.
2. **Inverted tap 7's sign** in the correlator's term selection -- on the
   `2'b01` branch. Tap 7's code is `2'b10`. The injection landed on a line that
   index never executes.
3. **Inverted tap 1**, whose code *is* `2'b01`. `lag 1` went from 0 mismatches
   to 64, and both benches that use the correlator failed.

The first two reported PASS, and both times that was correct: nothing had been
broken. **A control that passes has to be checked for vacuity before it can be
read as evidence** -- which is the same error as the DRIVE/SLEW heuristic, the
all-negated segbits signatures, the bank-wide `STEPDOWN` bit, and the
`stat -c` probe. Concluding from the absence of a failure, without first
establishing that a failure was possible.

`sim.py --selftest` now does this automatically, one injection per bench, and
each injection records *why* the line it edits is actually reached -- see below.

`regress.py` runs the suite, so the simulations are part of the regression
rather than a separate ritual.

## Every bench proved able to fail

One injection per bench, each aimed at what that bench exists to catch:

| injection | why the edited line is reached | caught by |
|---|---|---|
| tap 1's sign inverted | tap 1's code is `2'b01`, the edited branch | 4 of 4 |
| bridge read timeout disabled | the dead-slave read must then hang | 1 of 1 |
| per-sample lag bit forced to 0 | rates with a back-to-back strobe must mismatch | 1 of 1 |
| one bit of every captured sample flipped | the capture no longer matches the model | 1 of 1 |

All four caught. Before this, only the two correlator benches had a
demonstrated ability to fail; the bridge, the full path and the real-pin design
had none, and a suite of five in which three cannot fail is a suite of two.

The `note` field in each injection exists because of the two vacuous attempts
recorded above -- a control has to say why the line it edits is on a path the
test actually takes, or it is asserting nothing.
