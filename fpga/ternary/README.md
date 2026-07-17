# Ternary ZeroDSP matched filter -- the compact radio demod

The GF16 correlator (`../gf16/`) spends **8 DSP48E1** because every tap is a full
float multiply. But a matched filter's reference is a *code*, and a code is
naturally ternary `{-1, 0, +1}`. Multiplying a sample by a ternary tap is not a
multiply -- it is a sign-select (`+x`, `-x`, or `0`). So the whole correlator
collapses to a signed adder tree: **zero DSP, zero float normalization**.

This is the t27 "ZeroDSP MAC" idea (`t27/specs/fpga/mac.t27`,
`t27/fpga/verilog/ternary_mac_synth.v`) applied to the radio matched filter.
Ternary weight encoding follows GFTernary / that MAC: `2'b01 -> +1`,
`2'b10 -> -1`, else `0`. SSOT: `t27/specs/numeric/{tf3,gfternary}.t27`.

## Files

- `tern_corr8.v` -- combinational 8-tap ternary matched filter (sign-select +
  adder tree, parameterised sample/accumulator width).
- `tern_corr8_stream.v` -- streaming core: one signed sample/clock in, correlation
  out one clock later; 2-bit taps load through a config port.
- `tern_corr8_stream_tb.v` -- matched ternary code peaks (600 = 6 nonzero taps *
  amplitude 100), a zero-sum DC input nulls (0).
- `ota/` -- REAL over-the-air samples through this RTL.

## Measured, open-source (iverilog + yosys + nextpnr-xilinx, no Vivado)

Same xc7z020clg400-1 target and flow as the GF16 core, head to head:

| metric (xc7z020)        | GF16 `gf16_corr8_stream` | ternary `tern_corr8_stream` |
|-------------------------|--------------------------|-----------------------------|
| tap width               | 16-bit GF16 float        | **2-bit `{-1,0,+1}`**       |
| DSP48E1                 | 8                        | **0**                       |
| LUT (yosys)             | ~3138                    | **~540**                    |
| CARRY4                  | 315                      | **45**                      |
| FF                      | 273                      | 165                         |
| **Fmax (nextpnr STA)**  | **14.29 MHz**            | **78.21 MHz**               |
| full 30.72 MSPS native? | no (needs pipelining)    | **yes**                     |

Ternary is **~6x fewer LUTs, 0 DSP, and 5.5x higher Fmax.** 78 MHz clears the
full AD9361 30.72 MSPS with headroom -- no decimation and no pipelining, both of
which the GF16 core needed. The 8 freed DSP48E1 can go to channel filters or an
NCO.

## It demodulates the real air (ota/)

The same antenna-to-antenna capture used for the GF16 proof (board .13 TX a 1 MHz
tone, board .12 RX, tone at +0.96 MHz), fed through this ZeroDSP RTL with the
ternary sync code `sign(cos(2*pi*k/8))`:

| samples       | code               | RMS \|corr\| |
|---------------|--------------------|--------------|
| TX ON (real)  | matched            | **237.9**    |
| TX ON (real)  | mismatched (3x)    | 47.2 (~5x)   |
| TX OFF (real) | matched            | 14.0 (~17x)  |

The ternary code is a sign-only approximation of the cosine, so its
matched-vs-mismatched margin (~5x) is coarser than GF16's (~15x) -- but its
noise rejection is *better* (~17x vs 4x off), and for a real spread-spectrum
modem the reference IS a ternary PN code by design, so this is the right
primitive, not a compromise. See `ota/README.md`.

## Honest note

Ternary taps quantise the reference to signs only; they do not quantise the
received samples (those stay full int16 from the ADC). That is the correct
split: a matched filter's *code* is ternary, its *input* is the analog signal.
Carrier/timing recovery is still open (SOUL Article V) -- this matched a fixed
code at the measured tone bin.
