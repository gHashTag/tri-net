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
