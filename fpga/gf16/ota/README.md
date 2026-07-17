# Live over-the-air demod through the shipping correlator RTL

These files prove that `gf16_corr8_stream` -- the exact synthesizable GF16
matched-filter core -- demodulates a **real radio signal captured over the air**,
not a synthetic waveform.

## What was captured

- **TX (board .13):** AD9361 DDS single tone, 1 MHz baseband on a 2.400 GHz LO
  (transmits at 2.401 GHz), TX attenuation -20 dB.
- **RX (board .12):** AD9361, 2.400 GHz LO, 30.72 MSPS, manual gain 20 dB,
  8192 complex samples captured with `iio_readdev`. No cable -- antenna to
  antenna.
- The received tone landed at **+0.960 MHz** (carrier offset between the two
  crystals was only ~40 kHz on this pair), **SNR ~47 dB**. 32 samples/cycle.

## How the hex was made (data prep only, off the synthesis path)

1. `iio_readdev -s 8192 cf-ad9361-lpc voltage0 voltage1` on .12 -> interleaved
   int16 I/Q.
2. Take the I channel, remove DC, **decimate by 4** (32 -> 8 samples/cycle so one
   tone cycle fills the 8-tap window), normalise to +/-1.
3. GF16-encode each sample (`[S|E(6)|M(9)]`, bias 31) -> `rx_on.hex` /
   `rx_off.hex` (256 samples each, trimmed for a compact regression).
4. Reference taps = one cycle of a cosine: `taps_match.hex` = cos(2*pi*k/8),
   `taps_mismatch.hex` = cos(2*pi*3*k/8) (3x frequency, a wrong reference).

## The test

`ota_corr_tb.v` streams the real samples through `gf16_corr8_stream` (loading the
taps through the config port, driving all stimulus on `negedge` so the tap writes
do not race the clocked logic). It reports peak and RMS of `|corr|`.

```
iverilog -g2012 -o /tmp/ota ota_corr_tb.v \
    ../gf16_corr8_stream.v ../gf16_corr8.v ../gf16_dot4.v ../gf16_mul.v ../gf16_add.v
vvp /tmp/ota +SAMP=rx_on.hex  +TAPS=taps_match.hex    +N=256
vvp /tmp/ota +SAMP=rx_on.hex  +TAPS=taps_mismatch.hex +N=256
vvp /tmp/ota +SAMP=rx_off.hex +TAPS=taps_match.hex    +N=256
```

## Result (measured)

| samples        | taps               | peak \|corr\| | RMS \|corr\| |
|----------------|--------------------|---------------|--------------|
| TX ON (real)   | matched            | 3.50          | **2.30**     |
| TX ON (real)   | mismatched (3x f)  | 0.75          | **0.155**    |
| TX OFF (real)  | matched            | 1.70          | **0.55**     |

The matched filter separates the real received tone from a wrong reference by
~15x (RMS) and from the TX-off noise floor by ~4x. **The correlator we synthesize
is the correlator that demodulates the air.** This is the numeric core of the
radio modem that replaces the jittery shell-toggled DDS.

## Caveat (honest)

This is the DECIMATED path: samples fed at 7.68 MSPS (30.72/4). The one-cycle
combinational correlator places at **14.29 MHz** on xc7z020 (see ../README.md),
which clears 7.68 MSPS but not the full 30.72 MSPS -- full-rate operation needs
the multiply/add tree pipelined. Carrier/timing recovery is still open: this run
matched a cosine at the measured tone bin; a field modem must estimate that bin
on the fly (SOUL Article V).
