# What makes GF-T unique (measured)

GF-T (GoldenFloat-ternary) is the numeric format of the TRI-NET compute ring:
`[sign | balanced-ternary exponent trits | mantissa]`, value `(1 + M/2^mant) * 2^e`,
with the exponent in **balanced-ternary trits** (the golden identity `φ² + φ⁻² = 3`).

## 1. The 16-bit float shoot-out (measured)

`src/bin/gft16_vs_binary16.rs` round-trips real values through **four** 16-bit floats
over a 2^-40..2^40 sweep and prints these numbers (no claims):

| format | worst rel. error (whole range) | covers the sweep | dynamic range | character |
|---|---|---|---|---|
| **GF-T16** | **0.075% UNIFORM** | **100%** | ~2^81 (9e-13..2.2e12) | ternary exp, no subnormals/taper |
| binary16 | 0.031% normals / **94%** subnormals | 51% | ~2^40 (6e-8..6.6e4) | precise but narrow |
| bfloat16 | 0.224% (~3x coarser) | 100% | ~2^253 (widest) | wide but coarse (7-bit mant) |
| posit16 | 0.023% near 1 / **9.8%** at extremes | 100% | ~2^112 | great-near-1 but tapered + costly decode |

**GF-T16 owns the Pareto corner none of the others do: wide range AND uniform relative
precision AND cheap fixed-field decode.** binary16 is precise but narrow (fails on ~half
the sweep, subnormal collapse); bfloat16 is wide but ~3x coarser; posit16 is superb near 1
but tapers to ~9.8% at the extremes and needs a variable-length regime decode. GF-T16
holds ~0.075% *everywhere* across 2^81 of range -- the profile radio DSP and ternary/
BitNet-class compute (both dynamic-range-limited) actually need. Price: one mantissa bit
vs binary16 in the narrow band where binary16 works.

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

**Bit budget.** GF-T16 stores `offset<<9 | mant`: a 7-bit exponent offset (covering the
81 codes `0..80`) + a 9-bit mantissa = a **16-bit magnitude**; the sign is a separate bit,
so signed GF-T16 is **17 bits** vs binary16's 16 bits signed. GF-T16 therefore spends
~1 extra bit on the exponent (or, on ternary hardware, **4 native trits** = exactly 81
codes, no waste). The range + uniform-precision win costs ~1 bit, not zero — the "same
16 bits" framing holds for the *magnitude* field only. GF-T is designed for a ternary
substrate, where the exponent trits are the native unit.

**Precision.** binary16 is more precise **within its narrow range** (2x finer normals);
GF-T trades that for range + uniformity + cheap decode. All numbers above are the measured
output of the harness, not claims.
