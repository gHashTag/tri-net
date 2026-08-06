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
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_gfvalid.rs"]
mod gfvalid;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_safety.rs"]
mod safety;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_bitnet.rs"]
mod bitnet;
#[allow(dead_code, unused_parens)]
#[path = "../gen/rust/tri_compute_settle.rs"]
mod settle;

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

#[test]
fn width_binding_closes_precision_downgrade() {
    use a2a::*;
    // family + op are a lossy proxy: GFT16 and GFT8 share both.
    assert_eq!(skill_width(SKILL_GFT16_MUL), 16);
    assert_eq!(skill_width(SKILL_GFT8_MUL), 8);
    assert_eq!(skill_op(SKILL_GFT16_MUL), skill_op(SKILL_GFT8_MUL), "GFT16 and GFT8 share op");
    assert_eq!(skill_family(SKILL_GFT16_MUL), skill_family(SKILL_GFT8_MUL), "GFT16 and GFT8 share family");
    // Binding layer: the bare gate binds a GFT8 receipt to a GFT16 assignment; sized rejects.
    assert!(result_binds_assign(0x777, 0x777, 0x777, SKILL_GFT16_MUL, FMT_GFT, 0x11), "bare gate binds on family+op");
    assert!(!result_binds_assign_sized(0x777, 0x777, 0x777, SKILL_GFT16_MUL, FMT_GFT, 0x11, 8), "sized rejects a GFT8-width receipt for a GFT16 assignment");
    assert!(result_binds_assign_sized(0x777, 0x777, 0x777, SKILL_GFT16_MUL, FMT_GFT, 0x11, 16), "matching width binds");
    // Full ingress: admit_result_signed is width-blind; admit_result_signed_sized rejects the downgrade.
    let e = 0xE1u32;
    assert!(admit_result_signed(0x777, 0x777, 0x777, SKILL_GFT16_MUL, FMT_GFT, 0x11, 0x100, 100, 50, 2000, 10000, 2000, e, e, 1, e), "width-blind full gate admits the downgrade");
    assert!(!admit_result_signed_sized(0x777, 0x777, 0x777, SKILL_GFT16_MUL, FMT_GFT, 0x11, 0x100, 100, 50, 2000, 10000, 2000, e, e, 1, e, 8), "sized full gate rejects the GFT8 downgrade");
    assert!(admit_result_signed_sized(0x777, 0x777, 0x777, SKILL_GFT16_MUL, FMT_GFT, 0x11, 0x100, 100, 50, 2000, 10000, 2000, e, e, 1, e, 16), "sized full gate admits the matching width");
    // Never rescues a prior-gate failure even at the right width.
    assert!(!admit_result_signed_sized(0x777, 0x100, 0x100, SKILL_GFT16_MUL, FMT_GFT, 0x11, 0x100, 100, 50, 2000, 10000, 2000, e, e, 1, e, 16), "right width but stale still rejects");
}

// ---- non-terminal outcomes: challenger accountability ----

#[test]
fn challenger_stake_griefing_vs_nonfault() {
    use challenge::*;
    // A proven fraud (SLASH), a replay (STALE), and an unprovable split (INDETERMINATE)
    // all KEEP the challenger's stake -- the dispute was not the challenger's fault.
    assert_eq!(challenger_stake_after_bound(50, RESOLVE_SLASH), 50, "correct challenge keeps stake");
    assert_eq!(challenger_stake_after_bound(50, RESOLVE_STALE), 50, "replay is not griefing -> keep");
    assert_eq!(challenger_stake_after_bound(50, RESOLVE_INDETERMINATE), 50, "split proves nothing -> keep");
    // A frivolous (HONEST) or griefing (MALFORMED / FAMILY_MISMATCH) dispute BURNS it.
    assert_eq!(challenger_stake_after_bound(50, RESOLVE_HONEST), 0, "frivolous challenge burns stake");
    assert_eq!(challenger_stake_after_bound(50, RESOLVE_MALFORMED), 0, "malformed griefing burns stake");
    assert_eq!(challenger_stake_after_bound(50, RESOLVE_FAMILY_MISMATCH), 0, "family-confusion griefing burns stake");
}

#[test]
fn verifier_accountability() {
    use challenge::*;
    // A dissenter from a formed quorum is provably wrong -> stake burned; an agreeing
    // verifier keeps it. Honest verifiers split the burned dissenter stake.
    assert_eq!(verifier_stake_after(50, 1), 0, "dissenter burned");
    assert_eq!(verifier_stake_after(50, 0), 50, "agreeing verifier keeps stake");
    // 3 honest, 2 dissenters at 50 each -> 100 burned, split among 3 -> 33.
    assert_eq!(burned_total5(0x41, 0x41, 0x41, 0x99, 0xBE, 50), 100);
    assert_eq!(honest_share5(0x41, 0x41, 0x41, 0x99, 0xBE, 50), 33);
}

// ---- ternary validity + finiteness ----

#[test]
fn gft_validity_and_finiteness() {
    use gfvalid::*;
    // GF-T Et=4: 3^4 = 81 codes; offset_max = 80 is the reserved special row.
    assert!(is_valid_gft(0, 4), "offset 0 valid");
    assert!(is_valid_gft(79, 4), "offset just below the special row valid");
    assert!(!is_valid_gft(80, 4), "the special row (offset_max) is not a valid value");
    assert!(!is_valid_gft(81, 4), "out-of-range offset invalid");
    // is_finite_gft16 is the Et=4 alias.
    assert!(is_finite_gft16(79), "below special row -> finite");
    assert!(!is_finite_gft16(80), "special row -> not finite");
}

// ---- safety mint gate: all four guards ----

#[test]
fn payable_needs_all_four_guards() {
    use safety::*;
    // sig + fresh + finite + not-settled -> pays.
    assert_eq!(payable_authentic(1, 1, 1, 0), 1, "all four -> open");
    // dropping ANY single guard closes it.
    assert_eq!(payable_authentic(0, 1, 1, 0), 0, "no signature -> closed (forgery)");
    assert_eq!(payable_authentic(1, 0, 1, 0), 0, "stale -> closed (replay)");
    assert_eq!(payable_authentic(1, 1, 0, 0), 0, "inf/nan -> closed (garbage)");
    assert_eq!(payable_authentic(1, 1, 1, 1), 0, "already settled -> closed (double-pay)");
}

// ---- bitnet: 0b11 decodes to INACTIVE (the packing-malleability fix) ----

#[test]
fn bitnet_is_active_treats_0b11_as_inactive() {
    use bitnet::*;
    assert_eq!(is_active(1), 1, "0b01 -> active (+1)");
    assert_eq!(is_active(2), 1, "0b10 -> active (-1)");
    assert_eq!(is_active(0), 0, "0b00 -> inactive (skip)");
    assert_eq!(is_active(3), 0, "0b11 -> inactive, not a spurious active weight");
}

// ---- GF-T payability is RANGE-checked (out-of-range offset was garbage-paid) ----

#[test]
fn gft_payability_rejects_out_of_range() {
    use settle::*;
    // in-range finite offsets pay; the special row and anything past it withhold.
    assert_eq!(payable_flag(FMT_GFT, 0, 0, 0, 0, 80), 1, "offset 0 payable");
    assert_eq!(payable_flag(FMT_GFT, 79, 0, 0, 0, 80), 1, "boundary 79 payable");
    assert_eq!(payable_flag(FMT_GFT, 80, 0, 0, 0, 80), 0, "special row withheld");
    assert_eq!(payable_flag(FMT_GFT, 81, 0, 0, 0, 80), 0, "just past the ladder withheld");
    assert_eq!(payable_flag(FMT_GFT, 100, 0, 0, 0, 80), 0, "out-of-range withheld (was the garbage-pay hole)");
    assert_eq!(payable_flag(FMT_GFT, u32::MAX, 0, 0, 0, 80), 0, "max-u32 garbage withheld");
    // and settle actually withholds the reward for the garbage offset.
    assert_eq!(settle_checked_gft(100, 16, 1, 100, 80), 100, "out-of-range GF-T settles nothing");
    assert_eq!(settle_checked_gft(100, 16, 1, 40, 80), 116, "in-range GF-T still pays");
}

// GF-T payability must AGREE with gfvalid validity: pay iff the offset is a valid
// (in-range, non-special) GF-T code. This ties the settle gate to is_valid_gft so the
// two cannot drift (the range-blind is_finite_gft_n must never become the pay gate).
#[test]
fn gft_payability_matches_validity() {
    // Et=4 -> offset_max = 80.
    for off in [0u32, 1, 40, 79, 80, 81, 100, 1000, u32::MAX] {
        let payable = settle::payable_flag(settle::FMT_GFT, off, 0, 0, 0, 80) == 1;
        let valid = gfvalid::is_valid_gft(off, 4);
        assert_eq!(payable, valid, "payable_flag must equal is_valid_gft for offset {off}");
    }
}

// The primary (binary GF) payability path: exp is mask-bounded, so the only special
// values are the all-ones exponent AND only when the format actually carries Inf/NaN.
#[test]
fn binary_payability_withholds_only_inf_nan() {
    use settle::*;
    // GF16 (exp_bits 6, mant_bits 9, has_inf 1): all-ones exponent (0x3F) is Inf/NaN.
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x4200, 6, 9, 1, 0), 1, "GF16 finite value payable");
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x0000, 6, 9, 1, 0), 1, "GF16 zero (exp 0) is finite -> payable");
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x0001, 6, 9, 1, 0), 1, "GF16 subnormal (exp 0, mant!=0) payable");
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x7E00, 6, 9, 1, 0), 0, "GF16 +Inf (exp all-ones, mant 0) withheld");
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x7E01, 6, 9, 1, 0), 0, "GF16 NaN (exp all-ones, mant!=0) withheld");
    // A format WITHOUT Inf/NaN (has_inf 0, e.g. GF8): every exponent is a normal value.
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x70, 3, 4, 0, 0), 1, "GF8 max-exp with no Inf format -> normal, payable");
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x70, 3, 4, 1, 0), 0, "same pattern WITH has_inf -> withheld");
    // High garbage bits above the 15-bit GF16 field do not change the exp-field
    // verdict (the mask bounds exp to bits 9..14; the dispute layer catches a wrong
    // full value). Bit 20 set must not flip the finiteness classification.
    assert_eq!(payable_flag(FMT_GF_BINARY, 0x4200, 6, 9, 1, 0), payable_flag(FMT_GF_BINARY, 0x4200 | (1 << 20), 6, 9, 1, 0), "a high garbage bit does not change the exp-field verdict");
}
