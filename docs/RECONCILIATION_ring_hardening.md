# Reconciliation package: `feat/ring-hardening` -> `main`

**Purpose:** let the owner decide the merge strategy in minutes. This branch grew a
compute-market economic-security ring on a base (`1d425ab`) that predates the
parallel PR-train `#102-#110` now on `main`. The two evolved the same area
independently. Below: every increment, its reconciliation class, and the recipe.

**Status (2026-08-06):** 59 hardening increments on the branch; `feat/ring-hardening`
cannot fast-forward `main` (`origin/main` last observed at `#95-#110`).
The branch is verified in isolation and **the full ring is regression-free**: latest
verify-gate = all `tri_compute_*` + `tri_a2a` typecheck clean (0 errors), gen-rust
clean for all, 4 compute bins build, both lifecycle smokes pass. This is a
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
| `d800701` `c4f06de` | prepaid pool funding + pool-funded settle (reward moves, not minted; payouts <= deposits) | pool |
| `4657432` | payout overflow-scale regression (both mulDiv paths covered) | payout |
| `eb30bbc` `440d8ab` | bond collateralization + collateralized ingress (bond must scale with value at risk) | bond, a2a |
| `85ffeb8` `f8df5f0` | outstanding-escrow counter + `outstanding == pending` invariant (no fourth bucket) | account |
| `ff80921` `652c29b` | 5-node quorum `resolve_quorum5` + verifier economics on 5 nodes | challenge |
| `2fa8f0a` | signature guard added to the safety mint choke point (close forgery-pay) | safety |
| `5264242` `9c28f3a` `4a1bb42` `25b729a` | bitnet ternary hardening: 0b11-decodes-zero, canonical packing (no weight malleability), signed decode + popcount-MAC balance, verifiable ternary recompute | bitnet |
| `60c8874` `10c8a15` | resolve_bitnet + resolve_bitnet_quorum: a BitNet dispute verifies BOTH the ternary part and the GF value, under a verifier quorum | challenge |
| `f73b994` | lifecycle smoke proves the 5-node quorum economics end-to-end | src/bin |
| `9a8fc9a` | resolve_bitnet_quorum5 -- BitNet dispute over a 5-verifier quorum | challenge |
| `dbda24d` `aa12239` `4258d39` | close the u32 overflow class in every weight path: saturating payout.weighted/total_weighted3, reputation.weighted_work, pool.total_work3 (pool_share already u64-mulDiv) | payout, reputation, pool |
| `b325877` | lifecycle smoke: multi-task collateralization with a maintained outstanding counter | src/bin |
| `999e5bc` `ac2f8c6` | is_hosted_skill + family_matches_strict, wired into result_binds_assign: an unhosted/wider-ladder skill can no longer default to binary and accept a wrong-family receipt | a2a |
| `5238c58` | lifecycle smoke composes the BitNet dispute path (ternary recompute + quorum) end-to-end | src/bin |
| `d016e95` `1114843` `2b9e6d5` | gfvalid GF-T validity completed: is_finite_dispatch (route by family), gft_offset_in_range (port from #109 canon, reject out-of-range), is_valid_gft (one payable gate = in-range AND finite) | gfvalid |

Note: the gfvalid GF-T functions (gft_pow3/gft_offset_max/is_finite_gft_n/gft_offset_
in_range) are now **byte-identical to the #109 tri_gft_ladder canon** -- one more
place the merge collapses a duplicate rather than reconciling two.

### Security fixes -- the non-terminal-outcome / committed-transition class

The challenge layer grew non-terminal outcomes (MALFORMED, STALE, FAMILY_MISMATCH,
INDETERMINATE) over the ring, but three older consumers still treated "not honest" as
"slash / advance". A systematic audit found and fixed all three, plus a task-level
analogue -- these are **behavioral bug fixes** a reviewer should weigh, not pure
additions:

| Fix | Was | Now |
|-----|-----|-----|
| `50f1f40` bond_state_after | slashed the bond on ANY non-honest outcome | only a proven SLASH forfeits; non-terminal -> bond stays LOCKED (griefer can't forfeit an honest bond) |
| `5c9b777` challenger_stake_after_bound | burned the stake on INDETERMINATE | verifier split is not the challenger's fault -> stake kept |
| `e7c067e` resolver_epoch_after | advanced the dispute watermark on any non-STALE outcome | advance only on HONEST/SLASH -> a high-epoch MALFORMED can't stale-block legitimate disputes (replay-nonce DoS) |
| `079aaee` next_watermark_settled (a2a) | next_watermark advanced on freshness alone | settled-gated: an unsettled result can't jump the task watermark (same DoS at the task level) |

### Note on the bitnet increments

The bitnet ternary layer is **independent of the parallel #109/#110 GF-T work** (that
is GF-T *arithmetic*; bitnet is ternary *weight* attestation for BitNet-1.58 layers).
`resolve_bitnet*` consumes a `ternary_ok` flag the caller precomputes from
`bitnet_balance_matches` -- the same cross-module-flag pattern the quorum uses for the
GF recompute, so #110's arithmetic and this ternary check compose without conflict.

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
