# Reconciliation package: `feat/ring-hardening` -> `main`

**Purpose:** let the owner decide the merge strategy in minutes. This branch grew a
compute-market economic-security ring on a base (`1d425ab`) that predates the
parallel PR-train `#102-#110` now on `main`. The two evolved the same area
independently. Below: every increment, its reconciliation class, and the recipe.

**Status (2026-08-06):** 67 hardening increments on the branch; `feat/ring-hardening`.
**UPDATE: the merge is NOT blocked on a design decision** -- the "256-bit digest
collision" is convergent (my digest is byte-identical to and a subset of main's); the
merge is a mechanical rebase (drop the redundant digest commit, apply ~78 additive
functions). See the CORRECTION section below.
cannot fast-forward `main` (`origin/main` last observed at `#95-#110`).
The branch is verified in isolation and **the full ring is regression-free**: latest
verify-gate = all `tri_compute_*` + `tri_a2a` typecheck clean (0 errors), gen-rust
clean for all, 4 compute bins build, both lifecycle smokes pass. This is a
**mechanical rebase**, not a design decision (corrected below).

## CORRECTION: there is no design collision -- the digest CONVERGED

Earlier revisions of this doc claimed `ceae3e2` (my 256-bit receipt digest) collided
with main's `#106/#107` and needed an owner "pick a canonical digest" decision. **That
was wrong.** Verified against `origin/main` (`ded12d0`):

- My branch's `tri_compute_receipt.digest_pre` and `sign_digest` are **BYTE-IDENTICAL**
  to main's -- both arrived at the same single-block SHA-256 preimage independently.
- My branch's `tri_compute_receipt` is a strict **subset** of main's: main has every
  function mine has, PLUS `input_digest_pre` / `ledger_entry_pre` / `merkle_pair_pre`
  (#106/#108). Main also already has the `src/bin/trinet_receipt_digest.rs` bin.
- So `ceae3e2` is **entirely redundant with main** -- a rebase drops it (the content
  already exists). The conflict git reports there is **textual** (both added the
  digest to the same file region), resolved by taking main's superset. **No design
  choice.**

**The merge is mechanically tractable, not blocked on a decision.** The real work on
this branch is ~78 purely-additive functions (challenge 33, account 11, bitnet 11,
gfvalid 7, settle 5, pool 4, reputation 3, bond 2, safety 2) that **do not exist on
main** -- new functions in the same files, applying cleanly on top; any git conflict
is textual (keep both), never semantic.

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
| `cdd60c6` `80c9aa5` | account saturation: pending_after_settle (was wrapping while outstanding saturated -- broke the pending==outstanding invariant), and bal_add_sat for the settle/finalize mint path | account |
| `01d692e` | bitnet_leaf bound executor and epoch distinctly: the old `executor + epoch` summed the two identity fields, so (exec 5,epoch 3) and (exec 3,epoch 5) hashed to one leaf -- a cross-executor commitment collision, now split into two mix rounds | bitnet |
| `e2e117f` `ba72d2d` `df634c4` | **BitNet commitment lifted 32 -> 256 bit** (parity with the receipt digest): bitnet_digest_pre (SHA-256 preimage), resolve_bitnet_d256 (dispute anchors the 256-bit digest), and the lifecycle proof runs real tri_sha256 -- closes the ~2^16 birthday collision on BitNet attestations | bitnet, challenge, src/bin |
| `cd4f20c` `73dfd4c` | **GF dispute anchored on the 256-bit receipt digest** too (symmetry with BitNet): resolve_bound_d256 / resolve_full_d256, proven end-to-end in the lifecycle with real tri_sha256 -- both dispute paths now use a ~2^128 anchor instead of the 32-bit leaf | challenge, src/bin |

Audited but **not** an issue: `tri_compute_receipt` binds executor and epoch as
separate SHA-256 message words (idx 3 and 7) and separate mix rounds in its 32-bit
leaves -- it does **not** have the `bitnet_leaf` sum-collision. The commitment-
collision class is confined to (and fixed in) bitnet.

### The u32 overflow class is fully closed

Every product and weight-sum across the value layer is now overflow-safe: `pool_share`
(u64 mulDiv) + `total_work3` (pool), `weighted` + `total_weighted3` (payout),
`weighted_work` (reputation), `pending_after_settle` + `bal_add_sat` x3 (account). No
addition or product wraps; large ones saturate at u32 max. The account fix
`cdd60c6` was an invariant break (not mere overflow): `pending` wrapped while
`outstanding` saturated, so they diverged at the ceiling.

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

1. **No digest decision needed** -- `ceae3e2` is redundant with main (identical +
   subset); `git rebase --skip` it (or resolve by taking main's `tri_compute_receipt`).
2. Rebase `feat/ring-hardening` onto `origin/main`; the digest commit drops;
   `51adf59` collapses against `#109`; the ~78 additive functions apply cleanly (new fns,
   textual-only conflicts where two additions touch the same file region -- keep both).
3. Wire challenge -> `#110 verify_gft_mul_full` for the recompute (drop the oracle input).
   The quorum layer (`resolve_quorum3`, `verifier_*`) already consumes a recomputed
   value as input, so #110's arithmetic slots in without touching the economics.
4. Re-run the verify-gate: `t27c typecheck` all `tri_compute_*` + `tri_a2a*`, gen-rust
   all, `cargo build` the compute bins, run the lifecycle smokes.

### Test-merge confirmation (throwaway, verified against origin/main ded12d0..15ec65f)

A `git merge --no-commit feat/ring-hardening` into a throwaway copy of `origin/main`
produced **14 conflicted files, EVERY ONE an `add/add` textual conflict** -- both
sides appended to the same regions. There is **not one semantic/design conflict**.
Each resolves by taking my branch's version, which is either a pure addition (a2a
`is_hosted_skill`/`next_watermark_settled`, the collateralization block, etc.) or a
strict improvement of a function main left unchanged (e.g. `bond_state_after`: main
still has `else -> ST_SLASHED`; my branch has the non-terminal-outcome fix). Conflicted
files: a2a, a2a_wire, account, bitnet, bond, challenge, gfvalid, payout, pool, receipt,
reputation, safety, settle, trinet_a2a_node.rs. So the merge is a mechanical
"accept-branch / keep-both" resolution across ~14 files, then the verify-gate -- no
design decision anywhere.

**Resolution strategy (verified -- do NOT use `-X ours`/`-X theirs`):** a second
throwaway ran `git merge -X ours origin/main` and it **silently dropped main's
`ledger_entry_pre` / `merkle_pair_pre` / `input_digest_pre`** (#106/#108) -- they share a
conflict hunk with my digest additions in `tri_compute_receipt.t27`, so `-X ours` took my
(shorter) side. `-X theirs` would symmetrically drop my hardening. **Resolve each add/add
conflict as a UNION -- keep BOTH sides' functions** (both main's ledger/merkle AND my
additions survive). The only take-mine-not-both hunks are the ~2 functions I *changed*
that main left unchanged (`bond_state_after` non-terminal fix, `bal_after_settle`
saturation), where a union would duplicate a function. Then run the verify-gate.

Contact: this branch's session. Do not autonomous-merge -- see memory
`trinet-ring-hardening-divergence`.
