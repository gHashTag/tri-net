//! expiry_verdict_over_mesh -- the dispute game's EXPIRY path survives the distributed setting.
//! money_verdict_over_mesh proved a recomputed fraud verdict survives relaying; the expiry path
//! (challenge_lifecycle_e2e) is different in one crucial way: an expiry verdict asserts the ABSENCE
//! of proof, so a relay that turns "expired -> defender honest" into a SLASH frames a node that was
//! never proven wrong -- and a relay that turns a real SLASH into "expired" launders a fraudster.
//! Both directions must be tamper-evident. The drop case is SAFER here than for recomputed
//! verdicts: expiry is locally derivable (every settler has the dispute's opened_epoch and its own
//! clock), so a dropped expiry notice degrades to the settler's own dispute_expired() -- no message
//! is needed at all to settle an expired dispute; the wire only accelerates it.

// ---- challenge layer (transcribed: tri_challenge post-#311/#313) ----
const DEFENDER_HONEST: u32 = 1;
const DEFENDER_LIED: u32 = 2;
const UNPROVEN: u32 = 0; // non-terminal: bond stays escrowed
const RESOLVE_TIMEOUT: u32 = 27;

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
    } else if verdict == DEFENDER_LIED {
        0
    } else {
        defender_bond // unproven: nothing moves yet
    }
}

// ---- wire model (matching money_verdict_over_mesh) ----
const MAX_HOPS: u8 = 3;

fn mix32(x: u32) -> u32 {
    let mut h = x ^ 0x9E37_79B9;
    h = h.wrapping_mul(0x85EB_CA77);
    h ^= h >> 15;
    h
}
/// The tag binds BOTH the dispute id and the verdict, so neither can be swapped undetected
/// and an old dispute's expiry notice cannot be replayed onto a new dispute.
fn verdict_tag(dispute_id: u32, verdict: u32) -> u32 {
    mix32(dispute_id.rotate_left(7) ^ verdict.rotate_left(13) ^ 0x00E1_91E5)
}

type Wire = (u32, u32, u32); // (dispute_id, verdict, tag)

fn hop(ttl: u8, v: Wire) -> Option<(u8, Wire)> {
    if ttl == 0 {
        None
    } else {
        Some((ttl - 1, v))
    }
}
/// Deliver across `hops`; a relay at `flip_at` rewrites the verdict field (it cannot forge the tag).
fn deliver(hops: u32, dispute_id: u32, verdict: u32, flip_to: Option<(u32, u32)>) -> Option<Wire> {
    let mut ttl = MAX_HOPS;
    let mut v = (dispute_id, verdict, verdict_tag(dispute_id, verdict));
    for h in 0..hops {
        let (nt, mut nv) = hop(ttl, v)?;
        if let Some((at, forged)) = flip_to {
            if at == h {
                nv.1 = forged;
            }
        }
        ttl = nt;
        v = nv;
    }
    Some(v)
}
/// The settler accepts a delivered expiry/resolution verdict ONLY when the tag verifies for THIS
/// dispute; anything else is unproven.
fn accept(expected_dispute: u32, delivered: Option<Wire>) -> u32 {
    match delivered {
        Some((id, verdict, tag)) if id == expected_dispute && tag == verdict_tag(id, verdict) => {
            verdict
        }
        _ => UNPROVEN,
    }
}

const DISPUTE: u32 = 0xD15_0001;
const D_BOND: u32 = 150;
const C_BOND: u32 = 100;

#[test]
fn an_expiry_verdict_survives_relaying_and_settles_for_the_defender() {
    let v = accept(DISPUTE, deliver(2, DISPUTE, expired_verdict(), None));
    assert_eq!(v, DEFENDER_HONEST, "expiry notice delivered intact");
    assert_eq!(
        defender_bond_after(v, D_BOND, C_BOND),
        250,
        "defender collects both bonds"
    );
}

#[test]
fn a_relay_cannot_turn_expiry_into_a_slash() {
    // Framing attack: the challenger's collaborator rewrites "expired -> honest" into
    // DEFENDER_LIED to slash a node that was never proven wrong. The tag does not verify,
    // the settler treats it as unproven, and no bond moves on a forged message.
    let delivered = deliver(2, DISPUTE, expired_verdict(), Some((0, DEFENDER_LIED)));
    let v = accept(DISPUTE, delivered);
    assert_eq!(v, UNPROVEN, "forged slash is rejected, not applied");
    assert_eq!(
        defender_bond_after(v, D_BOND, C_BOND),
        D_BOND,
        "no proof, no bond movement"
    );
}

#[test]
fn a_relay_cannot_launder_a_real_slash_into_an_expiry() {
    // The mirror attack: a colluding relay rewrites a resolved DEFENDER_LIED into the
    // expiry verdict to hand the fraudster both bonds. Same tag failure, same safe default.
    let delivered = deliver(2, DISPUTE, DEFENDER_LIED, Some((1, expired_verdict())));
    let v = accept(DISPUTE, delivered);
    assert_eq!(v, UNPROVEN, "laundered expiry is rejected");
    assert_ne!(
        defender_bond_after(v, D_BOND, C_BOND),
        D_BOND + C_BOND,
        "the fraudster does not collect"
    );
}

#[test]
fn a_dropped_expiry_notice_degrades_to_the_local_clock_not_to_a_hang() {
    // TTL runs out: no expiry notice arrives. Unlike a recomputed verdict, expiry needs no
    // messenger -- the settler derives it from the dispute's opened epoch and its own clock.
    let dropped = deliver(u32::from(MAX_HOPS) + 1, DISPUTE, expired_verdict(), None);
    assert_eq!(
        accept(DISPUTE, dropped),
        UNPROVEN,
        "nothing arrived over the wire"
    );
    let (opened, now) = (500u32, 500 + RESOLVE_TIMEOUT + 1);
    assert!(
        dispute_expired(opened, now),
        "the settler's own clock reaches expiry"
    );
    let v = expired_verdict();
    assert_eq!(
        defender_bond_after(v, D_BOND, C_BOND),
        250,
        "locally derived expiry settles for the defender without any message"
    );
}

#[test]
fn an_old_expiry_notice_cannot_be_replayed_onto_a_new_dispute() {
    // The tag binds the dispute id: a captured expiry notice for DISPUTE does not verify
    // for a different dispute, so a challenger cannot recycle it to close a fresh case.
    let captured = deliver(2, DISPUTE, expired_verdict(), None);
    let other_dispute = DISPUTE ^ 0xFFFF;
    assert_eq!(
        accept(other_dispute, captured),
        UNPROVEN,
        "a notice for one dispute proves nothing about another"
    );
}
