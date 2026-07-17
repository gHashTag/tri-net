# Live over-the-air demod through the ZeroDSP ternary correlator

Same real capture as `../../gf16/ota/` (board .13 TX a 1 MHz tone, board .12 RX
at 30.72 MSPS, received tone at +0.96 MHz, SNR ~47 dB), but fed through the
ternary matched filter `tern_corr8_stream` -- **zero DSP, 2-bit taps.**

## Data

- `rx_on_raw.hex` / `rx_off_raw.hex` -- the I channel, DC-removed, decimated by 4
  (8 samples/cycle), as raw signed int16 (two's-complement hex). No float encode:
  ternary correlation needs none; the samples stay ADC-native.
- The ternary reference codes are hard-coded in `tern_ota_tb.v`:
  matched = `sign(cos(2*pi*k/8))` = `[+1,+1,0,-1,-1,-1,0,+1]`,
  mismatched = `sign(cos(2*pi*3*k/8))` = `[+1,-1,0,+1,-1,+1,0,-1]`.

## Run

```
iverilog -g2012 -o /tmp/tern ota/tern_ota_tb.v tern_corr8_stream.v tern_corr8.v
vvp /tmp/tern +SAMP=rx_on_raw.hex  +CODE=0 +N=256   # TX on, matched
vvp /tmp/tern +SAMP=rx_on_raw.hex  +CODE=1 +N=256   # TX on, mismatched
vvp /tmp/tern +SAMP=rx_off_raw.hex +CODE=0 +N=256   # TX off, matched
```

## Result (measured)

| samples       | code            | peak \|corr\| | RMS \|corr\| |
|---------------|-----------------|---------------|--------------|
| TX ON (real)  | matched         | 368           | **237.9**    |
| TX ON (real)  | mismatched (3x) | 104           | 47.2 (~5x)   |
| TX OFF (real) | matched         | 43            | 14.0 (~17x)  |

The ternary matched filter separates the real received tone from the TX-off
floor by ~17x and from a wrong code by ~5x -- with **no multiplier**. The
correlator that costs 0 DSP demodulates the air.
