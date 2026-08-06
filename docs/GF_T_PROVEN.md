# GF-T: what is proven, and what is not (honest scorecard)

GF-T (GoldenFloat-ternary) is a ternary-native floating ladder — GF-T4/8/16/32 built and
silicon-run, and the whole GoldenFloat catalog GF4..GF1024 proven in arithmetic — anchored on
φ (φ² + φ⁻² = 3). This is the evidence file: every claim below is backed by a runnable artifact in
this repo, and every open gap is named. It stays conservative — the goal is to earn "gold
standard" one day, not assert it.

## Proven (runnable in this repo)

| # | Claim | Evidence | Kind |
|---|-------|----------|------|
| 1 | GF-T16 owns the wide+uniform+cheap corner at 16 bits | `src/bin/gft16_vs_binary16.rs`, `docs/GF_T_ADVANTAGE.md` | measured |
| 2 | Wins **range-bound** task accuracy (dot product, RMSNorm) | `tests/gft_task_accuracy.rs`, `tests/gft_rmsnorm_accuracy.rs` (binary16 overflows) | cargo test |
| 3 | **Loses** precision-bound softmax to binary16 (honest boundary) | `tests/gft_softmax_accuracy.rs` | cargo test |
| 4 | **Model-level:** carries a 3-layer MLP 4× better than bf16 | `tests/gft_mlp_accuracy.rs` (GF-T16 0.082% vs bf16 0.326% vs int8 0.912%) | cargo test |
| 5 | One `.t27` drives Rust verifier + Verilog + a live FPGA | `specs/tri_gft_arith.t27` → `gen/rust` + `fpga/gft/*.v` | KAT |
| 6 | Verifiable compute: result **bound** to its input | `tests/gft_receipt_binding.rs` (sha2 + ed25519) | cargo test |
| 7 | Verifiable compute: **wrong** result recomputed + slashed | `tests/gft_compute_challenge.rs`, `tests/gft32_challenge.rs`, `tests/gft_verifiable_compute.rs` | cargo test |
| 8 | Workload + batch + settlement: dot / Merkle-batch / ledger | `tests/gft_dot_verifiable.rs`, `gft_receipt_batch.rs`, `gft_ledger_settlement.rs` | cargo test |
| 9 | **On silicon, 3 rungs:** GF-T8, GF-T16, GF-T32 multiply | `fpga/gft/gft_mul8/_mul/_mul32_ax7203.v`; 3/3, 5/5, 4/4 on AX7203 | on-chip |
| 10 | **On silicon:** GF-T16 MAC — dot2, streaming row, 4-lane tile | `gft_dot2/_macc/_dot4_ax7203.v`; 3/3, 4/4, 3/3 bit-exact | on-chip |
| 11 | The whole ladder GF4..GF1024 is real (exact to 632-bit mantissa) | `tests/goldenfloat_family_ladder.rs` (BigUint) | cargo test |
| 12 | A2A over-wire ring composes; both bridge endpoints compile | `src/bin/trinet_*_over_mesh.rs`; `docs/A2A_MESH_BRIDGE.md` | local test |

## The honest map

**GF-T16 is the format for wide-dynamic-range linear algebra, not a universal winner.** It wins
where dynamic range decides the answer (dot product, RMSNorm, and — measured — a multi-layer MLP,
4× better than bf16 at the same width) and where range beats bf16's coarse mantissa; it loses
precision-bound, mass-concentrated softmax to binary16's extra mantissa bit. Its exponent costs
~1 bit over binary16 in binary encoding, but is free on a ternary substrate. See
`docs/GF_T_ADVANTAGE.md` for the measured 4-way tables and `docs/VERIFIABLE_COMPUTE.md` for the
on-silicon vectors.

## NOT proven (the honest gaps)

- **Trained-model accuracy.** `gft_mlp_accuracy` is a real multi-layer forward pass but with
  fixed pseudo-random weights — format fidelity, not a trained network's convergence/inference vs
  int8/bf16 on a real task. This remains the biggest gap between "numerically good" and "industry
  impact"; the MLP is a step toward it, not a substitute.
- **Energy / Fmax.** Silicon proves *correctness*, not Watts-per-op or clock. `SYNTH_RESULTS.md`
  gives measured area only; no timing closure vs BitNet-class incumbents.
- **External validation.** No third party has reproduced or adopted GF-T. "Gold standard" is a
  status the field confers.
- **Higher ternary rungs on silicon.** GF-T64+ significand arithmetic is proven (BigUint, to
  GF1024), but their ternary Et per-rung geometry comes from the SSOT (`t27 specs/numeric/gft*.t27`)
  and is not yet transcribed/built; on silicon GF-T stops at GF-T32 (three rungs).
- **The A2A adapter.** Both endpoints compile (`trios-a2a` standalone + `trios-mesh` local); the
  `trios-a2a-mesh` adapter crate that wires them (per `docs/A2A_MESH_BRIDGE.md`) is unbuilt.

## Verdict

GF-T has a **proven numerical niche (measured, including a multi-layer MLP 4× better than bf16), a
spec-first pipeline that reaches real silicon across three rungs (GF-T8/16/32 — multiply, MAC,
streaming row, 4-lane tile, all bit-exact), a verifiable-compute ring settled into an optimistic
ledger (bound + correct + slashable + finalizing), and the whole GF4..GF1024 ladder proven in
exact arithmetic.** That is a strong, honest foundation — a *candidate* for a ternary/edge
standard. Calling it THE gold standard still requires the named gaps closed (a trained-model study,
energy on silicon, outside validation), not more self-measurement.
