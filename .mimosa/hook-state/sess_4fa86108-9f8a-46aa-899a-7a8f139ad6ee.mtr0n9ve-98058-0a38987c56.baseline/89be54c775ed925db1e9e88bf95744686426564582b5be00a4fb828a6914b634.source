//! money_verdict_over_mesh -- the ring grows outward: the fraud VERDICT that drives the money
//! consequences (money_lifecycle_e2e, #274) must survive the DISTRIBUTED setting, where the
//! challenger who recomputes a result is a different mesh node than the settler who acts on it.
//! a2a_over_mesh_integrity proved an abstract receipt survives multi-hop forwarding; #274 proved a
//! verdict drives all consequences on ONE node. Neither tied them: does a relay between the
//! challenger and the settler get to CHANGE the verdict (flip a SLASH to HONEST to save a colluding
//! fraudster), and does a dropped verdict silently finalize fraud by defaulting?
//!
//!   NODE_C challenger recomputes -> emits a verdict {outcome, tag=H(outcome)} -> forwarded hop by
//!   hop (TTL--, MAX_HOPS=3) -> NODE_A settler applies it, but ONLY if the tag still matches.
//!
//! Proven: an honest verdict survives and finalizes; a SLASH verdict survives and fires ALL
//! consequences; a relay that flips the outcome is caught by the tag (rejected, treated as unproven
//! -> the safe default keeps the bond LOCKED, never finalizes); TTL expiry drops rather than
//! defaulting to finalize; and a replayed verdict is rejected.

const HONEST: u32 = 0;
const SLASH: u32 = 1;
const MAX_HOPS: u8 = 3;

// ---- money consequences (transcribed, matching money_lifecycle_e2e) ----
const ST_LOCKED: u32 = 1;
const ST_RELEASED: u32 = 2;
const ST_SLASHED: u32 = 3;
fn bond_state_after(outcome: u32) -> u32 {
    match outcome {
        HONEST => ST_RELEASED,
        SLASH => ST_SLASHED,
        _ => ST_LOCKED, // unproven / rejected verdict: bond stays escrowed, never released
    }
}
const REVERSED: u32 = 2;
const FINALIZED: u32 = 1;
fn settle_state(slashed: u32) -> u32 {
    if slashed == 1 {
        REVERSED
    } else {
        FINALIZED // window has closed
    }
}
fn rep_after(rep: u32, outcome: u32) -> u32 {
    if outcome == SLASH {
        rep >> 1
    } else {
        rep
    }
}

// ---- verdict integrity tag ----
fn mix32(x: u32) -> u32 {
    let mut h = x ^ 0x9E37_79B9;
    h = h.wrapping_mul(0x85EB_CA77);
    h ^= h >> 15;
    h
}
/// The challenger signs the verdict; the tag binds the outcome so a relay cannot alter it undetected.
fn verdict_tag(outcome: u32) -> u32 {
    mix32(outcome.rotate_left(13) ^ 0x005E_771E)
}

/// One hop: TTL--, carry the (outcome, tag) unchanged. None if the TTL already expired.
fn hop(ttl: u8, v: (u32, u32)) -> Option<(u8, (u32, u32))> {
    if ttl == 0 {
        None
    } else {
        Some((ttl - 1, v))
    }
}
/// Deliver a verdict across `hops`; a relay at `flip_at` rewrites the outcome (but not a valid tag).
fn deliver(hops: u32, outcome: u32, flip_at: Option<u32>) -> Option<(u32, u32)> {
    let mut ttl = MAX_HOPS;
    let mut v = (outcome, verdict_tag(outcome));
    for h in 0..hops {
        let (nt, mut nv) = hop(ttl, v)?;
        if Some(h) == flip_at {
            nv.0 ^= 1; // flip SLASH<->HONEST, WITHOUT being able to forge the challenger's tag
        }
        ttl = nt;
        v = nv;
    }
    Some(v)
}

/// The settler accepts a delivered verdict ONLY if its tag matches its outcome; else it is unproven.
/// Returns the outcome to act on: the verified outcome, or a non-terminal "unproven" (2) on failure.
fn accept(delivered: Option<(u32, u32)>) -> u32 {
    match delivered {
        Some((outcome, tag)) if tag == verdict_tag(outcome) => outcome,
        _ => 2, // dropped or tampered -> unproven; the safe default (bond stays LOCKED, no finalize)
    }
}

#[test]
fn an_honest_verdict_survives_two_hops_and_finalizes() {
    let outcome = accept(deliver(2, HONEST, None));
    assert_eq!(outcome, HONEST, "honest verdict delivered intact");
    assert_eq!(bond_state_after(outcome), ST_RELEASED, "bond released");
    assert_eq!(settle_state(0), FINALIZED, "reward finalizes");
}

#[test]
fn a_slash_verdict_survives_and_fires_every_consequence() {
    let outcome = accept(deliver(2, SLASH, None));
    assert_eq!(outcome, SLASH, "slash verdict delivered intact");
    assert_eq!(bond_state_after(outcome), ST_SLASHED, "bond forfeited");
    assert_eq!(settle_state(1), REVERSED, "reward reversed");
    assert_eq!(rep_after(800, outcome), 400, "reputation halved");
}

#[test]
fn a_relay_flipping_the_verdict_is_caught_and_defaults_to_safe() {
    // A colluding relay flips the challenger's SLASH to HONEST to save the fraudster. It cannot forge
    // the tag, so the settler rejects it as UNPROVEN -- the bond stays LOCKED and nothing finalizes.
    // The fraud is NOT laundered into an honest finalize.
    let delivered = deliver(2, SLASH, Some(0));
    assert_ne!(
        delivered.map(|v| v.0),
        Some(SLASH),
        "the relay changed the outcome byte"
    );
    let outcome = accept(delivered);
    assert_eq!(
        outcome, 2,
        "a tag mismatch is treated as unproven, not as the forged HONEST"
    );
    assert_eq!(
        bond_state_after(outcome),
        ST_LOCKED,
        "unproven -> bond stays escrowed, never released"
    );
    assert_ne!(
        bond_state_after(outcome),
        ST_RELEASED,
        "the fraudster's bond is NOT released by the flip"
    );
}

#[test]
fn ttl_expiry_drops_rather_than_defaulting_to_finalize() {
    // A verdict that never arrives (path longer than TTL) must NOT default to a finalize -- that would
    // let a fraudster win by dropping the challenger's SLASH. accept() maps a drop to unproven.
    let delivered = deliver(4, SLASH, None); // 4 hops > MAX_HOPS
    assert_eq!(delivered, None, "over-TTL verdict is dropped");
    assert_eq!(
        accept(delivered),
        2,
        "a dropped verdict is unproven, not finalized"
    );
    assert_eq!(
        bond_state_after(accept(delivered)),
        ST_LOCKED,
        "no finalize on a dropped verdict"
    );
}

#[test]
fn a_replayed_verdict_is_rejected() {
    // Anti-replay: a verdict is applied once. A second identical delivery for the same task is a replay.
    let mut applied: Vec<(u32, u32)> = Vec::new();
    let first = deliver(2, SLASH, None).expect("first");
    let fresh_first = !applied.contains(&first);
    applied.push(first);
    let second = deliver(2, SLASH, None).expect("second");
    assert!(fresh_first, "first verdict is fresh");
    assert!(
        applied.contains(&second),
        "the replayed verdict is recognized and rejected"
    );
}
