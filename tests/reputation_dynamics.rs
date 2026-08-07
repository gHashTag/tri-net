//! reputation_dynamics -- CI guard for the SECURITY dynamics of the reputation layer (specs/
//! tri_compute_reputation.t27), which weights every pool payout. compute_ring_invariants pins only
//! the honest-gain cap; gft_rung_premium_consistency pins the rung scaling. The protective TEETH --
//! the outcome-driven transition, slash-with-memory, the repeated-fraud lockout, the anti-griefer
//! no-op on non-terminal outcomes, the u64 cap that stops an overflowing gain from zeroing an honest
//! node, and symmetric verifier accountability -- had no CI twin. This transcribes those functions
//! and pins them: the invariants that make a fraudster's reputation actually fall and lock it out.

const REP_MAX: u32 = 1000;
const RESOLVE_HONEST: u32 = 0;
const RESOLVE_SLASH: u32 = 1;
// non-terminal: 2=MALFORMED, 3=STALE, 4=FAMILY_MISMATCH

fn rep_after_honest(rep: u32, gain: u32) -> u32 {
    let r = (rep as u64) + (gain as u64);
    if r > REP_MAX as u64 {
        REP_MAX
    } else {
        r as u32
    }
}
fn rep_after_slash(rep: u32) -> u32 {
    rep >> 1
}
fn rep_after_resolution(rep: u32, outcome: u32, gain: u32) -> u32 {
    if outcome == RESOLVE_SLASH {
        rep_after_slash(rep)
    } else if outcome == RESOLVE_HONEST {
        rep_after_honest(rep, gain)
    } else {
        rep
    }
}
fn rep_after_verifier(rep: u32, has_quorum: u32, dissented: u32, gain: u32) -> u32 {
    if has_quorum == 1 {
        if dissented == 1 {
            rep_after_slash(rep)
        } else {
            rep_after_honest(rep, gain)
        }
    } else {
        rep
    }
}
fn can_admit(rep: u32, min_rep: u32) -> bool {
    rep >= min_rep
}

#[test]
fn the_outcome_drives_reputation() {
    assert_eq!(
        rep_after_resolution(1000, RESOLVE_SLASH, 20),
        500,
        "proven fraud halves"
    );
    assert_eq!(
        rep_after_resolution(100, RESOLVE_HONEST, 20),
        120,
        "proven honest gains"
    );
    assert_eq!(
        rep_after_resolution(990, RESOLVE_HONEST, 50),
        REP_MAX,
        "gain respects the cap"
    );
}

#[test]
fn a_slash_has_memory_one_honest_job_cannot_undo_it() {
    // 1000 -> slash 500 -> honest +20 = 520, still far below the pre-fraud 1000.
    let after_slash = rep_after_resolution(1000, RESOLVE_SLASH, 20);
    assert_eq!(after_slash, 500, "slash halves");
    assert_eq!(
        rep_after_resolution(after_slash, RESOLVE_HONEST, 20),
        520,
        "one honest job only partly repairs a proven slash"
    );
}

#[test]
fn repeated_fraud_halves_below_the_floor_and_locks_the_node_out() {
    // The entry-side teeth: 1000 -> 500 -> 250 -> 125 -> 62 -> 31. At floor 50 the fifth proven
    // fraud excludes the node from new work. Pin the exact halving chain and the crossing.
    let mut rep = 1000u32;
    let expected = [500u32, 250, 125, 62, 31];
    for (i, &e) in expected.iter().enumerate() {
        rep = rep_after_resolution(rep, RESOLVE_SLASH, 0);
        assert_eq!(rep, e, "fraud #{} leaves rep {e}", i + 1);
    }
    // Admission floor 50: admissible after 4 frauds (62), locked out after the 5th (31).
    assert!(can_admit(62, 50), "after 4 frauds (62) still admissible");
    assert!(
        !can_admit(31, 50),
        "the fifth proven fraud (31) locks the node out"
    );
}

#[test]
fn non_terminal_outcomes_never_move_reputation() {
    // A griefer must not tank an honest node (MALFORMED/FAMILY) nor dodge a penalty (STALE replay).
    for outcome in [2u32, 3, 4] {
        assert_eq!(
            rep_after_resolution(800, outcome, 20),
            800,
            "non-terminal outcome {outcome} is a no-op"
        );
    }
}

#[test]
fn an_overflowing_gain_cannot_zero_an_honest_node() {
    // A bare u32 `rep + gain` wraps: rep=1000, gain=0xFFFF_FC18 -> sum wraps to 0, which slips past
    // the `> REP_MAX` guard and would ZERO an honest node. The u64-widened sum caps at REP_MAX.
    assert_eq!(
        rep_after_honest(1000, 4_294_966_296),
        REP_MAX,
        "wrapping gain caps at REP_MAX, not 0"
    );
    assert_eq!(
        rep_after_honest(0, u32::MAX),
        REP_MAX,
        "a u32-max gain caps, no wrap"
    );
    let bare_wrap = 1000u32.wrapping_add(4_294_966_296);
    assert_eq!(bare_wrap, 0, "the wrap the u64 widening prevents");
    assert_eq!(
        rep_after_resolution(1000, RESOLVE_HONEST, 4_294_966_296),
        REP_MAX,
        "the driver caps an overflowing honest gain too"
    );
}

#[test]
fn verifiers_are_accountable_symmetrically() {
    // The same fraud proof judges the verifiers: dissent from a formed quorum halves, agreement
    // gains, no quorum is a no-op. A repeatedly-dissenting verifier is locked out like a fraudster.
    assert_eq!(
        rep_after_verifier(1000, 1, 1, 20),
        500,
        "dissenting verifier halved"
    );
    assert_eq!(
        rep_after_verifier(100, 1, 0, 20),
        120,
        "agreeing verifier gains"
    );
    assert_eq!(
        rep_after_verifier(800, 0, 0, 20),
        800,
        "no quorum -> unchanged"
    );
    assert_eq!(
        rep_after_verifier(800, 0, 1, 20),
        800,
        "no quorum: a dissent flag is ignored"
    );
    // Five dissents lock the verifier out under floor 50 (1000 -> 31).
    let mut rep = 1000u32;
    for _ in 0..5 {
        rep = rep_after_verifier(rep, 1, 1, 0);
    }
    assert_eq!(rep, 31, "five dissents -> 31");
    assert!(
        !can_admit(rep, 50),
        "a bad-track-record verifier is locked out too"
    );
}

#[test]
fn the_admission_floor_is_inclusive_and_excludes_a_zeroed_node() {
    assert!(can_admit(100, 50), "a fresh node (REP_INIT) is admissible");
    assert!(can_admit(50, 50), "exactly at the floor is admitted");
    assert!(!can_admit(49, 50), "one below the floor is excluded");
    assert!(!can_admit(0, 50), "a slashed-to-zero node cannot take work");
}
