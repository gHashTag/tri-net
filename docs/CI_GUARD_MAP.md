# CI guard map -- what the `cargo test` suite actually protects

The specs' own `test`/`invariant` blocks are only **parse + typecheck**ed by `t27c`
(its CI never executes assertions), and the `src/bin/trinet_*` end-to-end binaries are
**not cargo targets** (`autobins = false`). So a spec property is only regression-safe
if a declared `[[test]]` in `Cargo.toml` re-runs it under `cargo test`. This file maps
those CI-executed guards to the ring layer each protects, so a future change (or a new
session) can see coverage at a glance and not re-guard what is already covered.

**The real merge gate is the `build + test` CI job** (`.github/workflows/ci.yml`):
`cargo fmt --all --check` -> `cargo clippy --all-targets -- -D warnings` -> `cargo build`
-> `cargo test`. Reproduce it locally by **exit code**, not by grepping output:

```bash
cargo fmt --all --check;                       echo "fmt=$?"
cargo clippy --all-targets -- -D warnings;     echo "clippy=$?"
cargo test
```

> The separate `spec-drift-guard` workflow is **pre-existing red on `main`** (dozens of
> committed `gen/rust/*.rs` drift from the current upstream `t27c`; unrelated to any single
> PR). It is not the merge gate -- `build + test` is.

---

## Radio PHY -- the over-air link
| guard | property pinned |
|-------|-----------------|
| `ilv_interleaver` | block interleaver is an exact bijection (no datagram lost/duplicated) and spreads a burst of `<= depth` across distinct FEC codewords |
| `fec_ilv_burst_recovery` | **composition**: interleave -> burst -> de-interleave -> single-erasure XOR-FEC recovers a burst `<= depth` end to end; the same burst without interleaving, or `> depth`, is unrecoverable |

## Wire crypto -- the ChaCha20-Poly1305 frame
| guard | property pinned |
|-------|-----------------|
| `crypto_frame_replay` | 64-bit RFC-style anti-replay sliding window (lane-split); no accepted frame counter is ever accepted twice |
| `crypto_frame_nonce` | 12-byte nonce `[dir][epoch][counter]` is unique per frame; peer directions differ; ratchet at 2^20, hard-reject at 2^24 (never reuse a nonce) |

## Mesh transport -- multi-hop forwarding
| guard | property pinned |
|-------|-----------------|
| `a2a_over_mesh_integrity` | a signed result survives multi-hop forwarding; a tampered hop is detected |
| `a2a_mesh_antireplay` | a re-forwarded result cannot double-settle (task_id watermark) |
| `a2a_mesh_drop_conservation` | a dropped (TTL-expired) result delivers nothing, never a partial/stale value |
| `a2a_mesh_multipath` | a result delivered over multiple paths resolves consistently |
| `gft64_multihop_recompute_e2e` | recompute-and-slash survives A->B->C; a mid-path result rewrite is caught by the challenger's recompute |
| `gft_rung_over_wire` | the ladder rung binding survives mesh transport |
| `money_verdict_over_mesh` | the fraud VERDICT survives transport; a relay flipping SLASH->HONEST is caught (defaults to unproven, bond stays LOCKED); a dropped verdict never finalizes fraud |

## Membership & routing
| guard | property pinned |
|-------|-----------------|
| `discovery_beacon_gates` | HELLO beacon layout; a truncated beacon is rejected before its HMAC is read; a stale beacon cannot revive a dark node |
| `a2a_wire_decode` | wire header parse boundary; class validity; each operand binds to its own SHA preimage word (no operand swap under a signed receipt) |
| `a2a_card_routing` | skill -> (family, width, op) routing; a GF-T64 task is not mis-routed to a GF-T16 / binary host (regression for the #242/#243 fix) |

## Compute correctness & verifiable receipts
| guard | property pinned |
|-------|-----------------|
| `gft_verifiable_compute`, `gft_compute_challenge` | a wrong GF-T result is caught by recompute |
| `gft_receipt_binding`, `gft_receipt_batch` | a receipt is tamper-evident; a batch commits to one root, any member provable |
| `gft_dot_verifiable`, `gft_dot_oracle` | workload-level dot recompute-and-slash; folds in the silicon balanced-tree order (fixed #285) so it does not falsely slash an honest executor at >=4 lanes |
| `gft32_challenge`, `gft64_verifiable_compute_e2e`, `gft_sub_verifiable_e2e` | verifiable compute at GF-T32 / GF-T64 / subtract |
| `gft_rung_end_to_end` | the rung travels intact across every ring layer |
| `receipt_accept_policy` | the capstone accept policy: accepted iff signature AND membership AND correctness; reason names the first failing check |

## Silicon cross-guards (Rust <-> iverilog KAT)
| guard | property pinned |
|-------|-----------------|
| `gft_silicon_kat_cross` | GF-T4 / GF-T64 multiply matches the iverilog KAT |
| `gft64_add_dot_kat_cross` | GF-T64 add + dot2/dot4 match iverilog |
| `gft32_dot4_kat_cross` | GF-T32 4-lane MAC matches iverilog |
| `gft_sub_kat_cross` | GF-T subtract (all rungs) matches iverilog |

## Reduction order (GF-T add is non-associative)
| guard | property pinned |
|-------|-----------------|
| `gft_dot_reduction_order` | the canonical dot fold is the silicon balanced tree, not a left fold (GF-T16, 1-ULP divergence) |
| `gft64_dot_reduction_order` | same at the GF-T64 money rung (a 1-ULP disagreement is a payout disagreement) |
| `gft64_dot8_tree_order` | the 8-lane tile tree; the gap vs a flat fold grows to 2 ULP |
| `gft_dot_reorder_slash` | a reordered reduction is slashed like a wrong product |

_Spec source of truth:_ `specs/tri_gft_add.t27` defines `gft_dot4_offset/mant` (+`_p`
per-rung); the reduction order is normative there, not only in silicon.

## Money / economic security
| guard | property pinned |
|-------|-----------------|
| `pool_split_funding` | proportional floor-div split; no over-issuance; total payouts never exceed deposits (prepaid, not minted); rung enters once via width |
| `payout_no_over_issuance` | reputation-weighted shares never over-issue; saturation guards prevent a u32 wrap |
| `account_value_conservation` | lock/settle/finalize/clawback/slash never mint or leak value (total conserved) |
| `bond_collateralization_gate` | bond must cover outstanding value-at-risk, rung-scaled and monotone; under-collateralized is rejected |
| `optimistic_finality_lifecycle` | PENDING/FINALIZED/REVERSED; a SLASH reverses regardless of the window; only FINALIZED releases the bond |
| `reputation_dynamics` | slash halves with memory; repeated fraud locks out; non-terminal outcomes are no-ops; an overflowing gain cannot zero an honest node |
| `settle_mint_gate` | the reward computation / mint authorization: pays gf_width*REWARD iff signed AND fresh AND not-already-settled AND result finite; an inf/nan or out-of-range result mints nothing |
| `gfvalid_finiteness` | the validity gate feeding the mint: multi-format inf/nan detection (has_inf flag), GF-T ladder range+finiteness, and a FAIL-CLOSED width-derived offset_max (a crafted width cannot open the gate via a u32 underflow) |
| `gft_rung_premium_consistency` | the three rung-aware axes (window/bond/reputation) share one premium shape |
| `gft_ledger_settlement` | honest batches finalize into a tamper-evident chained head; a wrong dot cannot finalize |
| `money_lifecycle_e2e` | **composition**: one outcome drives every money layer to the SAME verdict; value conserved on both the honest and fraud paths |

## Numeric ladder (accuracy vs competitors)
`gft4_vs_bitnet`, `gft8_vs_fp8`, `gft_ladder_accuracy`, `gft_ladder_cures_tiny_weights`,
`gft_upper_rung_precision`, `gft_range_coverage`, `gft_sparsity_no_zero`,
`gft_mlp_accuracy`, `gft_rmsnorm_accuracy`, `gft_softmax_accuracy`, `gft_task_accuracy`,
`goldenfloat_conformance`, `goldenfloat_family_ladder`, `goldenfloat_ternary_ladder` --
the GF-T ladder's precision/range promises and honest head-to-head vs BitNet-1.58 / FP8.

---

## Known NOT-CI-guarded (honest gaps)
- **`tri_sha256` (the hand-written spec SHA-256)'s exact generated code** is not CI-run:
  it is used by production digest bins (`trinet_receipt_digest` / `_input_digest` /
  `_settle_signed`), but those bins are not cargo targets and its `gen/rust` is not
  CI-buildable (no `t27c` in the `build + test` job). Its `abc` KAT lives only in
  un-executed spec blocks. **Partially anchored** by `sha256_kat_anchor`: an independent
  NIST FIPS 180-4 SHA-256 pins the canonical KAT vectors, agrees with the `sha2` crate
  across block boundaries, and confirms the spec's `abc` h0..h7 are real SHA-256 -- so
  the ALGORITHM and expected values are CI-anchored even though the hand gen is not run.
- **`tri_merkle` / `tri_ledger`** use the non-cryptographic `mix32` (structural demos);
  the tamper-evident-commitment *concept* is CI-guarded with the real `sha2` hash in
  `gft_receipt_batch` / `gft_ledger_settlement`, not their exact `mix32` functions.
