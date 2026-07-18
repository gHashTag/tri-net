# PN spread spectrum over the air -- what is proven, what is not

An honest record of pushing a real PN-spread waveform through the AD9361 and
despreading the capture. Two claims, kept separate.

## RESOLVED (hardware): a clean byte over the air, BER=0

The "clean byte over the air" that three offline attempts (single-preamble,
multi-frame, M^2) stalled at 3-6/8 is now **done on real hardware** -- board .11
TX -> board .12 RX, 2.4 GHz, antenna to antenna. The offline attempts failed for
one reason: they were decoding old captures that had no proper frame structure,
using ad-hoc per-frame carrier guesses. The fix was to DESIGN the frame and
control the transmitter:

- **Frame:** a long known preamble (Barker-13 symbols, each spread by PN-63 =
  **819 chips**) + 8 data symbols carrying byte **0xA5** + guard, 16 samples/chip,
  BPSK on a +3 MHz IF subcarrier, transmitted hardware-cyclically
  (`iio_writedev -c`, no CPU busy-loop).
- **Receiver (host DSP):** (1) M^2-power coarse carrier -- estimate **+3.0022 MHz**
  vs the +3.000 MHz TX IF, the 2.2 kHz being the real oscillator offset between
  the two boards; (2) matched-filter acquisition against the 819-chip preamble --
  peak/mean **89.6x**, razor sharp; (3) coherent detection using the preamble
  correlation as the channel phase reference, despread each data symbol, slice.
- **Result:** **5 of 5** independently-acquired frames decoded **0xA5 exactly,
  BER=0** (majority 5/5).
- **Negative control:** TX off -> capture RMS drops 302 -> 13 (noise floor) and
  preamble lock collapses 89.6x -> 4.2x (no frame). So the clean byte was
  genuinely carried by the radio link, not a loopback or processing artifact.

The lesson the three offline waves pointed to -- "this is a receiver-SYNCHRONIZER
problem, not a limit of the ternary PHY" -- held exactly: a proper long-preamble
matched filter + M^2 carrier + coherent detection recovers the byte cleanly on
the first real capture. Everything below this section is the earlier honest record
of getting here.

### Extended: readable text over the air, BER=0 over 576 bits

Scaling one byte to a real message: TX a frame carrying the 24-char string
**"TRINET ternary OTA link "** (192 payload symbols) after the same 819-chip
preamble, .11 -> .12, 2.4 GHz. The receiver adds a decision-directed **Costas
loop** on top of the preamble acquisition (initial phase from the preamble, then
tracks the residual ~2.3 kHz oscillator offset across the 6.83 ms frame). Result:
**3 of 3 acquired frames recover the exact text, 0 bit errors over 576 bits
(BER = 0)**. The despread itself -- `vdot(received, PN)` with PN in {-1,+1} -- IS
the 0-DSP ternary sign-select correlator, so the ternary primitive is literally
what pulls the text off the air. This turns "a clean byte" into a **measured
radio link**: preamble sync + M^2 carrier + Costas tracking + ternary despread,
carrying readable data end to end on real hardware.

### Multi-node CDMA on ONE band (mesh multiple-access), on hardware

Two nodes share a single 2.4 GHz channel, separated only by PN code: board .11
transmits with m-sequence code A (x^6+x^5+1) carrying "NODE-A", board .13
transmits simultaneously with code B (x^6+x+1) carrying "NODE-B". Board .12
captures the SUM. The M^2 spectrum shows a single shared carrier (the two boards'
LOs sit within ~1 kHz -- likely a shared reference), and each node's message is
extracted at **BER=0** by its own code from the combined capture (`NODE-B` decodes
perfectly *through* code A's interference when B dominates; `NODE-A` decodes
perfectly when balanced toward A). This is the DSSS mesh multiple-access primitive
proven on air. The **near-far effect** was also characterized honestly: with
63-chip codes (~12 dB cross-correlation separation) the dominant node decodes
cleanly but equal-power co-channel users are mutually marginal -- the classic CDMA
power-control requirement (shifting a TX gain by a few dB flips which node
decodes). The standard fixes -- longer/Gold codes, power control, or successive
interference cancellation -- are the documented path to N equal-power nodes.

### Link margin on a bench: what a bench can and cannot show

At operating power the .11 -> .12 link is BER=0 with ~76x preamble lock; with the
transmitter off the band is quiet (capture RMS ~7, no bursts). A clean
BER-vs-power SENSITIVITY curve, however, did NOT come out of a software TX-gain
sweep on this two-antenna bench: at low signal levels the **decision-directed
Costas loop frays** (the 819-chip preamble still locks at 57-91x, but the 63-chip
payload symbols slice to ~50% once carrier tracking loses the weak signal), and
occasional transients contaminate individual captures. The honest reading: the
link works cleanly at operating power and the noise floor is characterized, but a
precise sensitivity/range curve needs calibrated attenuators (or a cabled/shielded
path) and a non-decision-directed carrier-recovery front end -- a bench with
software gain steps is the wrong instrument for that particular number.

## Proven: arbitrary-waveform DMA transmit over the air

The AD9361 TX path plays back arbitrary I/Q, not just DDS tones. Generating a
buffer on the host and feeding it continuously to `iio_writedev` on board .13
(`cf-ad9361-dds-core-lpc`, DDS scale 0 so the DMA source drives the DAC) puts
that waveform on 2.4 GHz. Board .12 received it strong (a test tone came back at
SNR ~34 dB, RMS ~700-800). One gotcha: a finite file redirected into
`iio_writedev` hits EOF and the buffer teardown stops TX -- feed it in a loop
(`while true; do cat buf; done | iio_writedev -b N ...`) to keep the DAC fed.

This is the enabling capability the DDS could never give: a real BPSK / PN /
BitNet-modulated waveform can leave the board over the air.

## Partly proven: PN despread with code discrimination

A length-63 m-sequence (the same one `tern_pn_lfsr` generates) was transmitted
as a BPSK baseband waveform and captured on .12. Despreading the complex capture
against the PN, at the alignment offset found by the correct code:

| reference at alignment    | correlation |
|---------------------------|-------------|
| correct PN                | 167470      |
| reversed PN (wrong code)  | 24729       |
| correct PN, 1 chip off    | 111605      |

The correct code beats a genuinely different (reversed) code by **~6.8x** -- real
over-the-air code detection. But two things fall short of the sim's textbook 63x
sidelobe rejection:

- **Shifted phases of the same code** are only rejected ~1.4x, not 63x, so clean
  CDMA node separation by code phase is NOT demonstrated over the air.
- The TX sample rate does not map to the assumed 30.72 MSPS (a 1 MHz-designed
  tone landed near 11 MHz), so the chips arrive coarsely sampled (~6 RX
  samples/chip) and the autocorrelation sidelobes smear.

## The honest boundary

The despreader RTL (`tern_corr_pn`) has perfect autocorrelation in simulation and
the ternary correlator demodulates a real tone OTA. Turning the ~6.8x OTA code
discrimination into the full 63x needs a proper acquisition front end: pin down
the actual DAC sample rate, match the RX chip clock, and derotate the carrier
offset before despreading. That is a bounded DSP task, not a limitation of the
ZeroDSP despreader. Not claimed as done.

## Update: proper DSSS acquisition recovers the code (6.8x -> 22.8x / 99.4x)

Re-processing the same capture (`rx_pn3.bin`) with a JOINT acquisition search --
carrier derotation x chip-rate -- instead of the naive despread found the real
signal parameters and lifted the result sharply:

- **Carrier offset: -3.2 MHz** (this matches the independent-crystal offset seen
  earlier; the two boards' XOs differ by ~3 MHz).
- **Chip rate: ~10 RX samples/chip** (the 128 samp/chip TX buffer compressed by
  the DAC's ~11x rate mapping).

At those parameters, despreading the real over-the-air capture:

| metric                              | value  |
|-------------------------------------|--------|
| correct-code peak / noise floor     | 22.8x  |
| correct vs a different (reversed) code | 99.4x |
| correct vs 1-chip-shifted code (CDMA) | 1.4x |
| correct, 1 chip off alignment       | 1.4x   |

So carrier derotation + chip timing turn the stuck 6.8x into a genuine **22.8x
processing gain and 99.4x rejection of a different code** -- spread spectrum is
really recovered over the air. The remaining soft spot is fine code-phase
resolution (1-chip CDMA still ~1.4x): at 10 samples/chip the chip edges are
smeared, so separating mesh nodes by 1-chip code-phase offsets needs
chip-synchronous matched filtering (a timing-recovery loop), not just the coarse
offset search. Honest state: OTA spread-spectrum PROVEN with real processing
gain; fine CDMA phase separation is the next refinement.

## Fine timing: fractional chip rate helps gain, NOT fine CDMA (capture-limited)

Tried the next refinement -- fractional chip-rate search + chip-synchronous
integrate-and-dump, refined around the correct alignment (chip rate 10.24
samples/chip, offset 16226):

- Raw processing gain improved: **peak/floor 22.8x -> 35.3x**.
- But **1-chip CDMA stayed ~1.4x** (shift+1), and half-chip early/late is
  1.1x/1.5x -- the fine code-phase resolution did NOT improve.

Honest finding: on THIS capture the fine CDMA phase separation is
**capture-limited, not timing-limited**. At ~10 RX samples/chip the chip edges
are smeared and the SNR is moderate, so no offline timing loop recovers 1-chip
node separation. The path to clean CDMA is a *fresh* capture with more
samples/chip (don't let the DMA rate-mapping compress the chips) or an on-board
chip-matched receiver -- not more offline processing of this file. The coarse
acquisition result (22.8x gain, 99.4x vs a different code) stands as the proven
OTA spread-spectrum; fine CDMA needs better data.

## SOLVED: the DMA-TX rate bug was the channel count

The earlier "tone at 11 MHz" rate compression that blocked clean captures for
several sessions had a simple cause: `iio_writedev cf-ad9361-dds-core-lpc` WITHOUT
naming channels enables ALL FOUR scan elements (voltage0..3 = TX1 I/Q + TX2 I/Q),
so a 2-channel I/Q buffer is read as 4-channel interleaved -> wrong sample
mapping -> the tone lands at the wrong frequency.

**Fix: name exactly the two channels** -> `iio_writedev -c -b N
cf-ad9361-dds-core-lpc voltage0 voltage1`. With that, a 2.00 MHz designed tone is
received at **+1.972 MHz, SNR 41 dB** -- correct frequency, no compression.
Arbitrary-waveform DMA-TX over the air now works at the right rate.

A clean PN capture (63 chips x 32 samples/chip, seamless cyclic) then despreads
with the fine 1-chip CDMA discrimination up from **1.4x to ~2.0x** (correct chip
rate = sharper chips). Not yet clean CDMA -- the remaining limit is SNR /
indoor multipath, not the rate bug. But the TX blocker that stalled the radio for
sessions is gone: clean, correct-rate captures are now possible, which is the
foundation the fine-CDMA and two-node link work needed.

## First DSSS-BPSK byte over the air (with the fixed TX): signal proven, decode partial

With the DMA-TX fix, transmitted a real frame -- preamble PN + 8 data symbols
(byte 0xA5), each bit spread by +/-PN-63 -- over the air, .13 -> .12.

- **The signal is clearly received**: at full TX power the preamble correlation
  is 14195 (10x the weak-power 1500) -- the spread-spectrum byte is unambiguously
  on the air and despreads strongly.
- **Bit decode is partial**: 6/8 bits at low power, and the errors are NOT random
  and NOT SNR-limited -- at full power the first ~4 bits invert. That signature is
  a **residual carrier frequency offset**: the constellation phase drifts ~pi
  across the 9-symbol frame and crosses the decision boundary mid-frame.

Honest finding: the physical link works (transmit + strong despread), but clean
BER=0 needs a proper **carrier-frequency estimate** -- a single 63-chip preamble
is too short to pin the frequency, so the phase drifts across the frame. The fix
is a longer-baseline estimator (correlate the preamble across the cyclic
repetitions) or a tracking loop / differential-coherent demod -- real receiver
DSP, a bounded next step, not an SNR or TX problem. Bytes are on the air; the
receiver's carrier recovery is what stands between 6/8 and 8/8.

## Clean byte NOT reached: it needs a real synchronized receiver, not offline patches

Tried a multi-frame coherent carrier estimator (sum the preamble across the
cyclic frame repetitions for a long baseline). It did not reach BER=0 -- still
5-6/8 -- and, tellingly, the acquisition parameters are INCONSISTENT across
attempts (carrier -298 / -148 / -50 kHz, spc 17 / 18 / 19). That inconsistency
says the problem is broader than carrier frequency: frame timing sync and
multipath ISI are also in play, and a short capture (~2 frame repetitions) is too
little baseline.

Honest boundary: the physical link is proven (bytes despread strongly on the
air), but a CLEAN byte needs a proper **synchronized DSSS receiver** -- frame
detection, a carrier tracking loop (Costas/FLL), and symbol-timing recovery
(early-late) working together -- not ad-hoc offline correlation. That is real
receiver engineering, a bounded project, not a 15-minute pass. Stopping the
ad-hoc receiver chase here (debugging discipline: several attempts, no
convergence -> the method, not the parameters, is the limit). The clean link is a
focused receiver task for a dedicated session.

## M-squared carrier estimator: also 3/8 -- boundary confirmed from 3 methods

Also tried the textbook M^2-power carrier estimator (square the BPSK-DSSS -> tone
at 2*fc). Best decode still 3/8, and for the strong capture the squared spectrum
peaks at DC (noise/LO-leakage dominates the weak 2*fc tone). Three independent
methods now -- single-preamble reference, multi-frame coherent, and M^2-power --
all land 3-6/8 on these captures. The boundary is confirmed: **offline processing
of these captures cannot reach BER=0**; a clean byte needs a real-time
synchronized receiver AND cleaner RF (less indoor multipath, higher SNR). Not
chasing further offline -- this is the spiral debugging discipline warns against.

## Synchronized-receiver reference model: the clean byte is a SYNC problem, not a fundamental one

The three offline decoders stalled at 3-6/8 because none of them was a real
receiver -- they lacked tracking loops. So instead of chasing the captures again,
I built a synchronized-receiver reference model (numpy, in the scratchpad) against
a channel with a realistic residual carrier-frequency offset (CFO), carrier phase,
fractional sample delay, clock ppm, and AWGN, and verified it BLOCK BY BLOCK
against a known frame (Barker-13 preamble + byte 0xA5 + guard, PN-63 spread,
8 samples/chip). What each block is now proven to do:

| block                          | method                              | verified result                          |
|--------------------------------|-------------------------------------|------------------------------------------|
| despread + slice (decode core) | matched filter to PN, sign slice    | pristine channel -> **0xA5, BER=0**      |
| coarse CFO estimate            | M^2-power (square -> tone at 2*CFO)  | true 0.0170 -> **est 0.0170** cyc/sample |
| carrier recovery (phase/ppm)   | decision-directed Costas loop       | static phase / 120 ppm / SNR 6 dB -> **0xA5, BER=0** |
| carrier recovery (freq offset) | Costas, fixed timing                | CFO 0.017 cyc/sample -> **0xA5, BER=0**  |
| frame sync + BPSK ambiguity    | Barker-13 correlation over symbols  | resolves frame start AND +/- phase       |

So every individual receiver block WORKS. The one piece that is not yet solid is
**joint fractional-timing + frame acquisition**: my successive ad-hoc timing
front-ends each fixed one impairment (CFO OR fractional delay) and regressed the
other -- the signature of a hand-tuned synchronizer rather than a proper joint
acquisition. The textbook fix is a matched-filter timing-recovery (interpolate to
the per-symbol correlation-peak instant, or a polyphase/Gardner TED wired to the
SAME derotated stream), acquired jointly with the Barker frame sync -- not more
hand-tuning. That is a bounded, well-understood synchronizer-design task.

**The result that matters:** "a clean byte over the air" is now shown to be a
receiver-SYNCHRONIZER problem, not a fundamental limit of the ternary PHY. Coarse
CFO, carrier recovery, despread, slice, and frame sync are each verified; the
remaining gap is one joint timing/frame acquisition block. This is the concrete,
decomposed spec for the "focused synchronized-receiver session" flagged earlier --
no longer a vague "needs a real receiver."
