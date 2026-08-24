//! optimistic_finality_lifecycle -- CI guard for the TIME dimension of optimistic settlement, the
//! partner of the bond gate's value dimension (bond_collateralization_gate). specs/
//! tri_compute_optimistic.t27 owns the PENDING -> FINALIZED / REVERSED state machine: a bonded
//! reward is credited provisionally, stays challengeable for a window, finalizes if unchallenged,
//! and is clawed back if slashed. gft_rung_premium_consistency already pins the window's rung
//! SCALING; the LIFECYCLE itself -- provisional credit needs a bond, the half-open window, the state
//! transitions, the clawback, and the time-safety invariant that a SLASH reverses REGARDLESS of the
//! window -- had no CI twin. This transcribes those functions and pins them.

const PENDING: u32 = 0;
const FINALIZED: u32 = 1;
const REVERSED: u32 = 2;

/// Provisional credit only if the executor's bond is posted (nothing to slash otherwise).
fn provisional_balance(prev_balance: u32, reward: u32, bond_ok: u32) -> u32 {
    if bond_ok == 1 {
        prev_balance + reward
    } else {
        prev_balance
    }
}

/// The window is open while now in [settled_at, settled_at + window) -- half-open.
fn window_open(now_epoch: u32, settled_at: u32, window: u32) -> bool {
    now_epoch < settled_at + window
}

/// A slash REVERSES regardless of the window; otherwise PENDING while open, FINALIZED once closed.
fn settle_state(window_is_open: u32, slashed: u32) -> u32 {
    if slashed == 1 {
        REVERSED
    } else if window_is_open == 1 {
        PENDING
    } else {
        FINALIZED
    }
}

/// A REVERSED settle claws back exactly the provisional reward (saturating at 0); else keeps it.
fn balance_after_settle(provisional_bal: u32, reward: u32, state: u32) -> u32 {
    if state == REVERSED {
        provisional_bal.saturating_sub(reward)
    } else {
        provisional_bal
    }
}

/// Only a FINALIZED settle may release the bond and confirm the credit.
fn can_finalize(state: u32) -> bool {
    state == FINALIZED
}

#[test]
fn provisional_credit_requires_a_posted_bond() {
    assert_eq!(
        provisional_balance(1000, 16, 1),
        1016,
        "bonded result credits the reward"
    );
    assert_eq!(
        provisional_balance(1000, 16, 0),
        1000,
        "unbonded result is NOT credited (nothing to slash)"
    );
}

#[test]
fn the_window_is_a_half_open_interval() {
    assert!(window_open(5, 3, 10), "epoch 5 within [3,13) -> open");
    assert!(
        !window_open(13, 3, 10),
        "epoch 13 == settled_at+window -> closed (half-open)"
    );
    assert!(!window_open(20, 3, 10), "well past -> closed");
    // The boundary is exactly settled_at+window: open below it, closed at/above it.
    for settled_at in 0..5u32 {
        for window in 1..8u32 {
            let boundary = settled_at + window;
            assert!(
                window_open(boundary - 1, settled_at, window),
                "just inside is open"
            );
            assert!(
                !window_open(boundary, settled_at, window),
                "the boundary epoch is closed"
            );
        }
    }
}

#[test]
fn a_slash_reverses_regardless_of_the_window() {
    // The time-safety invariant: fraud proven LATE (after the window) still reverses -- finalization
    // timing never defeats a slash. Exhaustive over (window_open, slashed).
    assert_eq!(
        settle_state(1, 0),
        PENDING,
        "in window, no challenge -> pending"
    );
    assert_eq!(
        settle_state(0, 0),
        FINALIZED,
        "window closed, no challenge -> finalized"
    );
    assert_eq!(
        settle_state(1, 1),
        REVERSED,
        "slashed in window -> reversed"
    );
    assert_eq!(
        settle_state(0, 1),
        REVERSED,
        "slashed AFTER the window -> STILL reversed"
    );
    // A settle is never simultaneously finalized and reversed.
    for w in 0..2u32 {
        for s in 0..2u32 {
            let st = settle_state(w, s);
            assert!(
                !(st == FINALIZED && st == REVERSED),
                "state is single-valued"
            );
            if s == 1 {
                assert_eq!(st, REVERSED, "any slash -> reversed");
            }
        }
    }
}

#[test]
fn a_reversal_claws_back_exactly_the_reward_and_never_underflows() {
    for &(bal, reward) in &[(1016u32, 16u32), (1000, 1000), (5, 500), (0, 1)] {
        let reversed = balance_after_settle(bal, reward, REVERSED);
        assert_eq!(
            reversed,
            bal.saturating_sub(reward),
            "clawback removes exactly the reward, saturating at 0"
        );
        // PENDING and FINALIZED keep the provisional reward -- only a proven slash claws it back.
        assert_eq!(
            balance_after_settle(bal, reward, PENDING),
            bal,
            "pending keeps it"
        );
        assert_eq!(
            balance_after_settle(bal, reward, FINALIZED),
            bal,
            "finalize keeps it"
        );
    }
}

#[test]
fn only_a_finalized_settle_can_release_the_bond() {
    assert!(can_finalize(FINALIZED), "finalized releases the bond");
    assert!(!can_finalize(PENDING), "pending cannot finalize yet");
    assert!(
        !can_finalize(REVERSED),
        "a reversed (slashed) settle can NEVER finalize -- bond stays forfeited"
    );
    // Tie the time-safety property together: a slash in OR out of the window yields a state that
    // cannot finalize, so a late fraud proof always keeps the bond from being released.
    assert!(
        !can_finalize(settle_state(1, 1)),
        "slashed in-window cannot finalize"
    );
    assert!(
        !can_finalize(settle_state(0, 1)),
        "slashed out-of-window cannot finalize either"
    );
}
