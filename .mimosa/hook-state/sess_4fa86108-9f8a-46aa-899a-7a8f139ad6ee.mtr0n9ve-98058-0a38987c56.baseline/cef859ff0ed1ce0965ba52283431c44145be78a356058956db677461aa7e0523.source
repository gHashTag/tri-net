//! challenge_lifecycle_e2e -- compose the dispute game's TIME dimension (tri_challenge) with the
//! optimistic settlement lifecycle (tri_compute_optimistic) into one scenario: settle a receipt,
//! open (or fail to open) a challenge, resolve or let it expire, and settle every bond and
//! balance -- asserting the two layers share ONE clock edge and ONE verdict. Designing this
//! composition caught a real seam: challenge_admissible's first cut used `<= window` while
//! window_open uses `now < settled_at + window`, so a challenge was admissible in the very epoch
//! the receipt finalized; the spec now uses the same strict edge, and this guard pins the two
//! gates to each other at every epoch so the seam cannot reopen.

// ---- tri_compute_optimistic (transcribed) ----
const PENDING: u32 = 0;
const FINALIZED: u32 = 1;
const REVERSED: u32 = 2;
const GFT16_ET: u32 = 4;
const BASE_WINDOW: u32 = 64;
const WINDOW_PER_TRIT: u32 = 16;

fn window_for_rung(gf_et: u32) -> u32 {
    if gf_et <= GFT16_ET {
        BASE_WINDOW
    } else {
        BASE_WINDOW + (gf_et - GFT16_ET) * WINDOW_PER_TRIT
    }
}
fn window_open(now_epoch: u32, settled_at: u32, window: u32) -> bool {
    now_epoch < (settled_at + window)
}
fn settle_state(window_is_open: u32, slashed: u32) -> u32 {
    if slashed == 1 {
        REVERSED
    } else if window_is_open == 1 {
        PENDING
    } else {
        FINALIZED
    }
}
fn balance_after_settle(provisional_bal: u32, reward: u32, state: u32) -> u32 {
    if state == REVERSED {
        provisional_bal.saturating_sub(reward)
    } else {
        provisional_bal
    }
}
fn can_finalize(state: u32) -> bool {
    state == FINALIZED
}

// ---- tri_challenge (transcribed, post-seam-fix) ----
const DEFENDER_HONEST: u32 = 1;
const DEFENDER_LIED: u32 = 2;
const RESOLVE_TIMEOUT: u32 = 27;

fn challenge_admissible(now_epoch: u32, receipt_epoch: u32, window: u32) -> bool {
    if now_epoch < receipt_epoch {
        return false;
    }
    (now_epoch - receipt_epoch) < window
}
fn resolve(defender_seal: u32, truth_seal: u32) -> u32 {
    if defender_seal == truth_seal {
        DEFENDER_HONEST
    } else {
        DEFENDER_LIED
    }
}
fn dispute_expired(opened_epoch: u32, now_epoch: u32) -> bool {
    if now_epoch < opened_epoch {
        return false;
    }
    (now_epoch - opened_epoch) > RESOLVE_TIMEOUT
}
fn expired_verdict() -> u32 {
    DEFENDER_HONEST
}
fn defender_bond_after(verdict: u32, defender_bond: u32, challenger_bond: u32) -> u32 {
    if verdict == DEFENDER_HONEST {
        defender_bond + challenger_bond
    } else {
        0
    }
}
fn challenger_bond_after(verdict: u32, defender_bond: u32, challenger_bond: u32) -> u32 {
    if verdict == DEFENDER_HONEST {
        0
    } else {
        challenger_bond + defender_bond
    }
}

/// The dispute verdict maps onto the optimistic layer's slashed flag: only a proven lie slashes.
fn slashed_flag(verdict: u32) -> u32 {
    if verdict == DEFENDER_LIED {
        1
    } else {
        0
    }
}

const SETTLED_AT: u32 = 1000;
const REWARD: u32 = 40;
const PROVISIONAL: u32 = 140; // balance 100 + reward 40, credited provisionally
const D_BOND: u32 = 150;
const C_BOND: u32 = 100;

#[test]
fn the_two_layers_share_one_window_edge_at_every_epoch() {
    // The seam this guard exists for: at EVERY epoch around the window, a challenge is
    // admissible exactly when the optimistic window is open -- for the flagship rung and a
    // wide rung alike. One clock, one edge, no epoch where a finalized receipt is challengeable.
    for et in [4u32, 9] {
        let w = window_for_rung(et);
        for now in SETTLED_AT..(SETTLED_AT + w + 3) {
            assert_eq!(
                challenge_admissible(now, SETTLED_AT, w),
                window_open(now, SETTLED_AT, w),
                "admissibility == open window at epoch {now} (Et{et}, window {w})"
            );
        }
    }
}

#[test]
fn a_proven_lie_reverses_the_reward_and_forfeits_the_defender_bond() {
    let w = window_for_rung(GFT16_ET);
    let now = SETTLED_AT + 10;
    assert!(
        challenge_admissible(now, SETTLED_AT, w),
        "challenge opens inside the window"
    );
    let verdict = resolve(0xDEAD_BEEF, 0x7157_0000); // defender seal != recomputed truth
    assert_eq!(verdict, DEFENDER_LIED);
    let state = settle_state(
        u32::from(window_open(now, SETTLED_AT, w)),
        slashed_flag(verdict),
    );
    assert_eq!(state, REVERSED, "a slash reverses even inside the window");
    assert_eq!(
        balance_after_settle(PROVISIONAL, REWARD, state),
        100,
        "reward clawed back"
    );
    assert!(
        !can_finalize(state),
        "a reversed receipt can never finalize"
    );
    let (da, ca) = (
        defender_bond_after(verdict, D_BOND, C_BOND),
        challenger_bond_after(verdict, D_BOND, C_BOND),
    );
    assert_eq!(
        (da, ca),
        (0, 250),
        "liar forfeits its dispute bond to the challenger"
    );
    assert_eq!(da + ca, D_BOND + C_BOND, "dispute bonds conserved");
}

#[test]
fn a_frivolous_challenge_costs_the_challenger_and_the_receipt_still_finalizes() {
    let w = window_for_rung(GFT16_ET);
    let now = SETTLED_AT + 10;
    assert!(challenge_admissible(now, SETTLED_AT, w));
    let verdict = resolve(0x7157_0000, 0x7157_0000); // defender matches the truth
    assert_eq!(verdict, DEFENDER_HONEST);
    let state_now = settle_state(
        u32::from(window_open(now, SETTLED_AT, w)),
        slashed_flag(verdict),
    );
    assert_eq!(
        state_now, PENDING,
        "an honest receipt stays pending inside the window"
    );
    assert_eq!(
        balance_after_settle(PROVISIONAL, REWARD, state_now),
        PROVISIONAL
    );
    let after = SETTLED_AT + w;
    let state_after = settle_state(u32::from(window_open(after, SETTLED_AT, w)), 0);
    assert!(
        can_finalize(state_after),
        "the window closes and the reward stands"
    );
    let ca = challenger_bond_after(verdict, D_BOND, C_BOND);
    assert_eq!(ca, 0, "the frivolous challenger forfeits its bond");
}

#[test]
fn an_unresolved_challenge_expires_for_the_defender_within_a_bounded_lifetime() {
    let w = window_for_rung(GFT16_ET);
    let opened = SETTLED_AT + w - 1; // the LAST admissible epoch
    assert!(challenge_admissible(opened, SETTLED_AT, w));
    // Nobody recomputes the truth; the dispute must expire, not hang.
    let deadline = opened + RESOLVE_TIMEOUT + 1;
    assert!(
        !dispute_expired(opened, deadline - 1),
        "live until the timeout fully elapses"
    );
    assert!(
        dispute_expired(opened, deadline),
        "expired one epoch past the timeout"
    );
    let verdict = expired_verdict();
    let state = settle_state(
        u32::from(window_open(deadline, SETTLED_AT, w)),
        slashed_flag(verdict),
    );
    assert!(
        can_finalize(state),
        "no proof, no slash: the receipt finalizes after expiry"
    );
    assert_eq!(
        balance_after_settle(PROVISIONAL, REWARD, state),
        PROVISIONAL,
        "reward stands"
    );
    assert_eq!(
        challenger_bond_after(verdict, D_BOND, C_BOND),
        0,
        "the non-resolving challenger forfeits"
    );
    // The whole dispute game is bounded: worst-case finalization epoch is
    // settled_at + window - 1 + RESOLVE_TIMEOUT + 1.
    assert_eq!(
        deadline,
        SETTLED_AT + w + RESOLVE_TIMEOUT,
        "bounded dispute lifetime"
    );
}

#[test]
fn past_the_window_no_challenge_can_touch_a_finalized_receipt() {
    let w = window_for_rung(GFT16_ET);
    let late = SETTLED_AT + w; // the finalization epoch itself
    assert!(
        !challenge_admissible(late, SETTLED_AT, w),
        "the finalization epoch admits nothing"
    );
    let state = settle_state(u32::from(window_open(late, SETTLED_AT, w)), 0);
    assert!(
        can_finalize(state),
        "the receipt is final at that same epoch"
    );
    assert_eq!(
        balance_after_settle(PROVISIONAL, REWARD, state),
        PROVISIONAL
    );
}
