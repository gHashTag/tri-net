# What makes GF-T unique (measured)

GF-T (GoldenFloat-ternary) is the numeric format of the TRI-NET compute ring:
`[sign | balanced-ternary exponent trits | mantissa]`, value `(1 + M/2^mant) * 2^e`,
with the exponent in **balanced-ternary trits** (the golden identity `φ² + φ⁻² = 3`).

## 1. Ternary exponent -> far more dynamic range per bit

`src/bin/gft16_vs_binary16.rs` round-trips real values through GF-T16 and IEEE
binary16 (both 16-bit) and **measures** the gap over a 2^-40..2^40 sweep:

| | GF-T16 | IEEE binary16 |
|---|---|---|
| layout | `s \| 4 exp trits \| 9 mant` | `s \| 5 exp bits \| 10 mant` |
| exponent codes | **81** (e in -40..40) | 32 (e in -14..15) |
| dynamic range | **9.1e-13 .. 2.2e12** (~2^81) | 6.0e-8 .. 6.6e4 (~2^40) |
| worst rel. error | **0.075% uniform** (no subnormals) | 0.031% normals / **94% subnormals** |
| covers the 2^-40..2^40 sweep | **100%** | 51% (rest over/underflows) |

So at the **same 16 bits**, GF-T16 has **~2^41x more dynamic range** than binary16,
and its relative precision is **uniform** across the whole range -- binary16's
collapses near the 2^-24 underflow floor (subnormals). The price is one mantissa bit
(~2x coarser normal-range precision). For radio DSP and ternary/BitNet-class neural
compute -- both dynamic-range-limited -- that trade wins: GF-T16 does not overflow at
6.6e4 or underflow at 6e-8, where binary16 fails on ~half a wide sweep.

```bash
rustc -O --edition 2021 src/bin/gft16_vs_binary16.rs -o /tmp/gftbench && /tmp/gftbench
```

## 2. No regime/tapered decode -> cheap silicon

Unlike posit/tapered formats (variable-length regime bits, costly decode), GF-T has
**fixed-width fields** -- decode is a plain field split. Measured: one GF-T16 multiply
synthesizes to **1 DSP48E1 + ~47 LUT** (`fpga/gft/gft16_mul.v`, `SYNTH.md`); a 4-lane
MAC tile is 4 DSP48E1, so an xc7a200t fits ~180 tiles.

## 3. One ladder, one spec, both targets

GF-T4/8/16/32 are one family with per-rung geometry (`tri_gft_ladder.t27`), and one
`.t27` generates BOTH the Rust A2A over-wire verifier AND synthesizable Verilog, proven
to agree (`fpga/gft/gft_*_gen_kat_tb.v`). All four rungs verify end-to-end over the
sealed mesh (`trinet_gft32_over_mesh` closes the u64 rung), each against an exact oracle.

## Honest boundaries

binary16 is more precise **within its narrow range** (2x finer normals); GF-T trades
that for range + uniformity + cheap decode. The numbers above are the measured output of
the harness, not claims.
