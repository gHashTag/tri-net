# GF-T: what is proven, and what is not (honest scorecard)

GF-T (GoldenFloat-ternary) is a ternary-native floating ladder — GF-T4/8/16/32 — anchored on
φ (φ² + φ⁻² = 3). This is the evidence file: every claim below is backed by a runnable artifact
in this repo, and every open gap is named. It is deliberately conservative — the goal is to be
able to say "gold standard" one day *because it was earned*, not asserted.

## Proven (runnable in this repo)

| # | Claim | Evidence | Kind |
|---|-------|----------|------|
| 1 | GF-T16 owns the wide+uniform+cheap corner at 16 bits | `src/bin/gft16_vs_binary16.rs`, `docs/GF_T_ADVANTAGE.md` | measured |
| 2 | It wins **range-bound** task accuracy (dot product) | `tests/gft_task_accuracy.rs` (wide band: binary16 overflows, GF-T16 0.00067%) | cargo test |
| 3 | It **loses** precision-bound softmax to binary16 | `tests/gft_softmax_accuracy.rs` (binary16 wins both bands) | cargo test |
| 4 | It wins **range-bound** RMSNorm | `tests/gft_rmsnorm_accuracy.rs` (wide band: binary16 overflows) | cargo test |
| 5 | The arithmetic is spec-first: one `.t27` drives Rust + Verilog | `specs/tri_gft_arith.t27` → `gen/rust` + `fpga/gft/*.v` | KAT |
| 6 | A compute result is cryptographically **bound** to its input | `tests/gft_receipt_binding.rs` (sha2 + ed25519, tamper → reject) | cargo test |
| 7 | A **wrong** result is caught (recompute + slash) | `tests/gft_compute_challenge.rs` (off-by-one & near-miss slashed) | cargo test |
| 8 | GF-T16 **multiply** runs on real silicon, bit-exact | `fpga/gft/gft_mul_ax7203.v`; 5/5 on AX7203 (`docs/VERIFIABLE_COMPUTE.md`) | on-chip |
| 9 | GF-T16 **dot product (MAC)** runs on silicon, bit-exact | `fpga/gft/gft_dot2_ax7203.v`; 3/3 on AX7203 | on-chip |
| 10 | Variable-length **matmul row** streams on silicon-ready RTL | `fpga/gft/gft_macc_ax7203.v` (iverilog KAT; on-chip pending flash) | KAT + synth |
| 11 | The A2A over-wire ring composes end-to-end | `tests/compute_ring_invariants.rs`, `src/bin/trinet_*_over_mesh.rs` | local test |

## The honest map

**GF-T16 is the format for wide-dynamic-range linear algebra, not a universal winner.** It wins
where dynamic range decides the answer (dot product, RMSNorm — where binary16 overflows) and where
range beats bf16's coarse mantissa; it loses precision-bound, mass-concentrated softmax to
binary16's extra mantissa bit. Its exponent costs ~1 bit over binary16 in binary encoding, but is
free on a ternary substrate (4 native trits = exactly 81 codes). See `docs/GF_T_ADVANTAGE.md` for
the measured 4-way tables.

## NOT proven (the honest gaps)

- **Model accuracy.** No trained model has been run in GF-T. The task tests above are synthetic
  micro-kernels, not a convergence/inference study vs int8/bf16. This is the single biggest gap
  between "numerically good" and "industry impact".
- **Energy / Fmax.** Silicon proves *correctness*, not Watts-per-op or clock. `SYNTH_RESULTS.md`
  gives area only; no timing closure vs BitNet-class incumbents.
- **External validation.** No third-party has reproduced or adopted GF-T. "Gold standard" is a
  status the field confers, not one this repo can assert.
- **On-chip MAC-row.** `gft_macc` is KAT'd + synthesized; the streaming dot product is flash-pending.

## Verdict

GF-T has a **proven numerical niche, a spec-first pipeline that reaches real silicon (multiply +
MAC, bit-exact), and a verifiable-compute ring (bound + correct + slashable).** That is a strong,
honest foundation — a *candidate* for a ternary/edge-arithmetic standard. Calling it the gold
standard requires the three gaps above closed (model study, energy on silicon, outside validation),
not more self-measurement.
