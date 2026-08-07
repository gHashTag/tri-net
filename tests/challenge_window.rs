//! challenge_window -- CI guard for the dispute game's TIME dimension (specs/tri_challenge.t27).
//! The challenge game had no clock: nothing bounded when a dispute may open, and an OPEN dispute
//! nobody resolved had no defined outcome. The spec now binds challenges to the optimistic
//! finality window and gives unresolved disputes an expiry verdict that sides with the DEFENDER
//! (no recomputed truth = no proof; anything else would let a challenger freeze-and-slash any
//! node by never resolving). This transcribes those functions (spec test blocks run under the
//! icarus flow, but the merge gate is cargo test) and pins the edges and the settlement
//! composition.

const DEFENDER_HONEST: u32 = 1;
const DEFENDER_LIED: u32 = 2;
const RESOLVE_TIMEOUT: u32 = 27;

fn challenge_admissible(now_epoch: u32, receipt_epoch: u32, window: u32) -> bool {
    if now_epoch < receipt_epoch {
        return false; // fail closed on a non-monotone clock
    }
    (now_epoch - receipt_epoch) < window
}
fn dispute_expired(opened_epoch: u32, now_epoch: u32) -> bool {
    if now_epoch < opened_epoch {
        return false; // fail closed on a non-monotone clock
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

#[test]
fn the_window_gate_is_exact_at_both_edges() {
    assert!(
        challenge_admissible(100, 100, 8),
        "fresh receipt is challengeable"
    );
    assert!(
        challenge_admissible(107, 100, 8),
        "last in-window epoch (window - 1) is challengeable"
    );
    assert!(
        !challenge_admissible(108, 100, 8),
        "the finalization epoch itself admits no challenge"
    );
    assert!(
        !challenge_admissible(99, 100, 8),
        "a backwards clock admits nothing"
    );
    assert!(
        !challenge_admissible(5, 5, 0),
        "a zero window admits nothing at all"
    );
    assert!(
        !challenge_admissible(6, 5, 0),
        "a zero window closes immediately after"
    );
}

#[test]
fn expiry_is_exact_at_the_timeout_edge_and_fail_closed() {
    assert!(
        !dispute_expired(50, 50 + RESOLVE_TIMEOUT),
        "at the timeout the dispute is live"
    );
    assert!(
        dispute_expired(50, 50 + RESOLVE_TIMEOUT + 1),
        "one epoch past the timeout expires"
    );
    assert!(
        !dispute_expired(50, 49),
        "a backwards clock never expires a dispute"
    );
    assert!(
        !dispute_expired(u32::MAX - 1, u32::MAX),
        "near-overflow epochs stay inside checked arithmetic"
    );
}

#[test]
fn an_expired_dispute_settles_exactly_like_a_failed_challenge() {
    // No proof -> no slash: the defender keeps both bonds, the non-resolving challenger
    // forfeits, and the expiry path conserves total bond like every resolved path.
    let v = expired_verdict();
    assert_eq!(v, DEFENDER_HONEST, "expiry sides with the defender");
    let da = defender_bond_after(v, 150, 100);
    let ca = challenger_bond_after(v, 150, 100);
    assert_eq!(
        (da, ca),
        (250, 0),
        "defender keeps both bonds; challenger forfeits"
    );
    assert_eq!(da + ca, 250, "total bond conserved on the expiry path");
}

#[test]
fn every_verdict_path_conserves_the_total_bond() {
    for verdict in [DEFENDER_HONEST, DEFENDER_LIED] {
        for (db, cb) in [(100u32, 100u32), (150, 100), (1, 0), (0, 1)] {
            let da = defender_bond_after(verdict, db, cb);
            let ca = challenger_bond_after(verdict, db, cb);
            assert_eq!(
                da + ca,
                db + cb,
                "bond conservation for verdict {verdict} ({db},{cb})"
            );
        }
    }
}

#[test]
fn the_window_and_expiry_compose_into_a_bounded_dispute_lifetime() {
    // A receipt with window W challenged at the last admissible epoch and never resolved
    // is fully settled by receipt_epoch + W + RESOLVE_TIMEOUT + 1 -- the dispute game
    // cannot hold a receipt hostage longer than that bound.
    let (receipt_epoch, window) = (1000u32, 8u32);
    let opened = receipt_epoch + window - 1; // last admissible epoch
    assert!(challenge_admissible(opened, receipt_epoch, window));
    let settled_by = opened + RESOLVE_TIMEOUT + 1;
    assert!(
        dispute_expired(opened, settled_by),
        "the dispute cannot outlive the bound"
    );
    assert!(
        !dispute_expired(opened, settled_by - 1),
        "and settles no earlier than the timeout allows"
    );
}
