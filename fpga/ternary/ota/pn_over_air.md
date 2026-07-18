# PN spread spectrum over the air -- what is proven, what is not

An honest record of pushing a real PN-spread waveform through the AD9361 and
despreading the capture. Two claims, kept separate.

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
