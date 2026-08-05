# Reconciliation package: `feat/ring-hardening` -> `main`

**Purpose:** let the owner decide the merge strategy in minutes. This branch grew a
compute-market economic-security ring on a base (`1d425ab`) that predates the
parallel PR-train `#102-#110` now on `main`. The two evolved the same area
independently. Below: every increment, its reconciliation class, and the recipe.

**Status (2026-08-06):** 29 hardening increments on the branch; `feat/ring-hardening`
cannot fast-forward `main` (`origin/main` last observed at `#95-#110`, sha `3f2bc4c`).
The branch is verified in isolation and **the full ring is regression-free**: latest
verify-gate = 14/14 `tri_compute_*` + `tri_a2a*` typecheck clean (0 errors),
gen-rust clean for all, 4 compute bins build, both lifecycle smokes pass. This is a
**merge-strategy decision**, not a mechanical conflict.

## The one true collision (needs an owner pick)

| Mine | Main | Conflict |
|------|------|----------|
| `ceae3e2` 256-bit SHA-256 canonical receipt digest (`tri_compute_receipt`) | `#106`/`#107` 256-bit ledger head + hardened signed 256-bit path | **Two independent 256-bit digest designs.** A rebase stops at this commit first. Pick one canonical digest; re-express the other side's callers against it. |

Everything else is additive or complementary and does **not** collide this way.

## Complementary to `#110` (GF-T arithmetic) -- they compose, keep both

`#110 tri_gft_arith.t27` *produces* the golden GF-T recompute (`gft_mul_offset`,
`gft_mul_mant`, `verify_gft_mul_full`). My challenge layer *consumes* a recomputed
result and binds it to economics. On merge, wire my challenge to CALL
`verify_gft_mul_full` instead of taking `recomputed_result` as an opaque oracle.

| Mine | Composes with |
|------|---------------|
| `3ce9c15` bind fraud proof to settled leaf | `#110` verdict feeds `resolve_bound` |
| `5ab0523` anti-replay + GF-T family binding | `#110` family/arith |
| `c331334` verifier quorum (2-of-3) over the recompute | `#110` recompute is what the verifiers run |

## Duplicate of `#109` -- already aligned (pre-emptive)

| Mine | Main | Action |
|------|------|--------|
| `51adf59` generalized GF-T finiteness (`gft_pow3`/`gft_offset_max`/`is_finite_gft_n`) | `#109 tri_gft_ladder.t27` (same three fns) | **Byte-identical by design.** Merge deletes one copy; my `is_finite_gft16` stays a thin Et=4 alias. |

## Additive & independent (no main equivalent -- lift as-is)

All verified; none of these functions exist on `main`.

| Increment | Adds | Spec |
|-----------|------|------|
| `a27a7dc` `226a84c` has_inf-aware finite gate + settlement | only GF16 has Inf/NaN | gfvalid, settle |
| `f33278b` `payable_flag` + `settle_canonical` | one payability truth + one settlement choke point | settle |
| `b7aca42` optimistic settlement escrow (`pending`) | reward non-spendable until the window | account |
| `cb16051` epoch-gated finality (`is_final`) | finalize only after `settle_epoch + window` | account |
| `d6b7eeb` `pool_share` u64 widening | fixes an overflow that over-issues at scale | pool |
| `df27a55` `compute_reward_fmt` + `99e4bc2` `settle_canonical_fmt` | format-aware reward, flat = identity | settle |
| `a6c346f` `rep_after_resolution` | drive reputation from the challenge outcome | reputation |
| `3051a4a` `can_admit` | min-rep admission gate (lock out repeat fraud) | reputation |
| `4e720be` `verifier_dissented` / `verifier_stake_after` | dissent from the quorum burns the verifier's stake | challenge |
| `6b99ee3` `quorum_threshold` / `has_quorum_k` / `max_agree3` | generalize the quorum to k-of-n | challenge |
| `3e1349d` `rep_after_verifier` | drive verifier reputation from dissent (symmetric to executor) | reputation |
| `13b42e2` `verifier_reward` | reward honest verifiers from the burned stake (verifier's dilemma) | challenge |
| `97fd9cf` `op_matches` / `result_binds_assign` | a mul assignment must not settle an add receipt | a2a |
| `61bdeaa` `admit_result` | one ingress gate: binding AND freshness AND reputation | a2a |
| `d800701` `pool_after_deposit` / `payout_capped` / `pool_after_payout` | prepaid funding: payouts never exceed deposits | pool |
| `c4f06de` `balance_after_pool_settle` | reward MOVES from the funded pool, not minted (conserved) | pool |
| `314a1f0` `354e364` `3e3fabd` `d6f2f1c` | lifecycle smoke: two-sided penalties, verifier reward, real recompute, ingress-gated settle | src/bin |

## Recommended recipe

1. **Decide the digest** (`ceae3e2` vs `#106/#107`) -- the only design call.
2. Rebase `feat/ring-hardening` onto `origin/main`; resolve the digest commit per (1);
   `51adf59` collapses against `#109`; the additive commits apply cleanly (new fns).
3. Wire challenge -> `#110 verify_gft_mul_full` for the recompute (drop the oracle input).
   The quorum layer (`resolve_quorum3`, `verifier_*`) already consumes a recomputed
   value as input, so #110's arithmetic slots in without touching the economics.
4. Re-run the verify-gate: `t27c typecheck` all `tri_compute_*` + `tri_a2a*`, gen-rust
   all, `cargo build` the compute bins, run the lifecycle smokes.

Contact: this branch's session. Do not autonomous-merge -- see memory
`trinet-ring-hardening-divergence`.
