//! Durable value-regression tests for the compute-receipt / A2A hardening.
//!
//! The specs' own `test` blocks are only PARSED + TYPECHECKED by t27c (t27c ci is
//! parse+typecheck+gen+seal; it never executes assertions), and the end-to-end proof
//! in src/bin/trinet_compute_lifecycle.rs is not a cargo target (autobins = false), so
//! until now the ring's hardening was verified ONLY by ephemeral commit-time harnesses.
//! This file re-runs the load-bearing invariants under `cargo test`, so a regression
//! that silently reverts a hardened gate (e.g. burned_total5 back to a bare multiply,
//! or a resolver losing its freshness wrapper) is caught by committed CI.
//!
//! The generated modules are self-contained, so we include them directly by path
//! rather than through the lib (which does not re-export the compute ring).

#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_challenge.rs"]
mod challenge;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_account.rs"]
mod account;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_reputation.rs"]
mod reputation;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_pool.rs"]
mod pool;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_bond.rs"]
mod bond;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_a2a.rs"]
mod a2a;

// ---- overflow class: saturation, not wrap ----

#[test]
fn burned_total5_saturates_not_wraps() {
    use challenge::*;
    assert_eq!(burned_total5(0x41, 0x42, 0x43, 0x44, 0x45, 100), 400, "small stake exact");
    // 4 * 1.1e9 = 4.4e9 overflows u32; a bare multiply would wrap to 105_032_704.
    assert_eq!(4_400_000_000u64 as u32, 105_032_704);
    assert_eq!(burned_total5(0x41, 0x42, 0x43, 0x44, 0x45, 1_100_000_000), 4_294_967_295, "saturates");
}

#[test]
fn credit_adds_saturate_not_wrap() {
    // account mint, pool-settle credit, and bond release all cap at u32 max.
    assert_eq!(account::bal_add_sat(0xFFFF_FFF0, 200), 0xFFFF_FFFF);
    assert_eq!(account::bal_add_sat(500, 200), 700);
    assert_eq!(pool::balance_after_pool_settle(0xFFFF_FFF0, 1000, 300), 0xFFFF_FFFF, "pool credit saturates");
    assert_eq!(pool::balance_after_pool_settle(500, 1000, 300), 800, "normal pool credit exact");
    assert_eq!(bond::balance_after_resolve(0xFFFF_FFF0, 200, 0), 0xFFFF_FFFF, "honest bond release saturates");
    assert_eq!(bond::balance_after_resolve(0xFFFF_FFF0, 200, 1), 0xFFFF_FFF0, "slash never adds");
}

#[test]
fn reputation_cap_survives_overflowing_gain() {
    use reputation::*;
    assert_eq!(rep_after_honest(100, 20), 120, "normal gain exact");
    assert_eq!(rep_after_honest(990, 50), REP_MAX, "finite-large gain caps");
    // rep=1000 + gain=0xFFFFFC18 wraps a u32 sum to exactly 0; the cap must still hold.
    assert_eq!(rep_after_honest(1000, 4_294_966_296), REP_MAX, "overflowing gain caps, not zeroes");
}

// ---- dispute anti-replay: every resolver family member is STALE on replay ----

#[test]
fn every_resolver_is_stale_on_replay() {
    use challenge::*;
    let (gft, bin) = (FMT_GFT, FMT_GF_BINARY);
    assert_eq!(resolve_full(5, 5, bin, bin, 0xAB, 0xAB, 0x9999, 0x4100), RESOLVE_STALE);
    assert_eq!(resolve_full_d256(5, 5, bin, bin, 1, 0x9999, 0x4100), RESOLVE_STALE);
    assert_eq!(resolve_bitnet_full(6, 6, gft, gft, 0xAB, 0xAB, 0x9999, 0x4100, 1), RESOLVE_STALE);
    assert_eq!(resolve_bitnet_quorum_full(6, 6, gft, gft, 0xAB, 0xAB, 0x9999, 0x4100, 0x4100, 0x9999, 1, 1, 1), RESOLVE_STALE);
    assert_eq!(resolve_bitnet_quorum5_full(6, 6, gft, gft, 0xAB, 0xAB, 0x9999, 0x4100, 0x4100, 0x4100, 0x9999, 0x9999, 1, 1, 1, 1, 1), RESOLVE_STALE);
    assert_eq!(resolve_bitnet_d256_full(6, 6, gft, gft, 1, 0x9999, 0x4100, 1), RESOLVE_STALE);
}

#[test]
fn every_resolver_is_family_mismatch_cross_family() {
    use challenge::*;
    let (gft, bin) = (FMT_GFT, FMT_GF_BINARY);
    assert_eq!(resolve_full(0, 6, bin, gft, 0xAB, 0xAB, 0x9999, 0x4100), RESOLVE_FAMILY_MISMATCH);
    assert_eq!(resolve_bitnet_full(0, 6, gft, bin, 0xAB, 0xAB, 0x4100, 0x4100, 1), RESOLVE_FAMILY_MISMATCH);
    assert_eq!(resolve_bitnet_quorum_full(0, 6, gft, bin, 0xAB, 0xAB, 0x4100, 0x4100, 0x4100, 0x4100, 1, 1, 1), RESOLVE_FAMILY_MISMATCH);
    assert_eq!(resolve_bitnet_d256_full(0, 6, gft, bin, 1, 0x4100, 0x4100, 1), RESOLVE_FAMILY_MISMATCH);
}

#[test]
fn fresh_fraud_still_slashes() {
    use challenge::*;
    let (gft, bin) = (FMT_GFT, FMT_GF_BINARY);
    assert_eq!(resolve_full(0, 6, bin, bin, 0xAB, 0xAB, 0x9999, 0x4100), RESOLVE_SLASH);
    assert_eq!(resolve_bitnet_full(0, 6, gft, gft, 0xAB, 0xAB, 0x9999, 0x4100, 1), RESOLVE_SLASH);
    assert_eq!(resolve_bitnet_d256_full(0, 6, gft, gft, 1, 0x9999, 0x4100, 1), RESOLVE_SLASH);
}

// ---- escrow / finality ----

#[test]
fn slashed_reward_never_finalizes() {
    use account::*;
    assert_eq!(bal_after_finalize_checked(500, 16, 0, 100, 10, 0), 516, "clean reward finalizes after window");
    assert_eq!(bal_after_finalize_checked(500, 16, 0, 100, 10, 1), 500, "slashed never finalizes");
    assert_eq!(bal_after_finalize_checked(500, 16, 0, 999_999, 10, 1), 500, "slashed blocked no matter the clock");
}

#[test]
fn clawback_removes_reward_from_pending() {
    use account::*;
    let pend0 = pending_after_settle(0, 16);
    assert_eq!(pend0, 16);
    assert_eq!(pending_after_release(pend0, 16), 0, "clawback empties pending");
    assert_eq!(pending_after_release(10, 20), 0, "over-release floors, no underflow");
}

// ---- A2A authenticated ingress ----

#[test]
fn admit_result_signed_rejects_forge_and_frontrun() {
    use a2a::*;
    let (task, wm, exe) = (0x777u32, 0x100u32, 0xE0E0u32);
    assert!(admit_result_signed(task, task, task, SKILL_GF16_MUL, 0, 0x11, wm, 100, 50, 2000, 10000, 2000, exe, exe, 1, exe), "honest authentic admission");
    assert!(!admit_result_signed(task, task, task, SKILL_GF16_MUL, 0, 0x11, wm, 100, 50, 2000, 10000, 2000, exe, 0xBEEF, 1, 0xBEEF), "front-run rejected");
    assert!(!admit_result_signed(task, task, task, SKILL_GF16_MUL, 0, 0x11, wm, 100, 50, 2000, 10000, 2000, exe, exe, 0, exe), "forge (unsigned) rejected");
    assert!(!admit_result_signed(task, task, task, SKILL_GF16_MUL, 0, 0x11, wm, 100, 50, 2000, 10000, 2000, exe, exe, 1, 0xBEEF), "identity mismatch rejected");
    assert!(!admit_result_signed(task, task, task, SKILL_GF16_MUL, 0, 0x11, wm, 100, 50, 1999, 10000, 2000, exe, exe, 1, exe), "under-collateralized rejected");
}
