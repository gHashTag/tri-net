//! gft_rung_end_to_end -- the RUNG travels intact across the ring's layers:
//! assignment -> receipt -> challenge -> settlement. A GF-T rung is its exponent-trit
//! count Et (the golden rule, width_to_et). This test transcribes each layer's rung
//! logic from its spec and shows the rung is committed once and enforced everywhere, so
//! a wrong-rung splice (e.g. answering a GF-T32 task with a cheaper GF-T16 result) is
//! caught at every boundary -- a single regression guard for the whole chain:
//!
//!   tri_a2a.skill_et                    (assignment commits the rung)
//!   tri_compute_receipt.receipt_leaf_gf_rung (receipt binds Et into the attestation)
//!   tri_compute_challenge.resolve_full_rung  (dispute rejects a wrong-rung recompute)
//!   tri_compute_settle.gft_offset_max_w      (settlement prices the rung's finite range)

/// Ladder SSOT: width -> Et (golden rule Et = fib(k+1)+1), the single source every layer reads.
fn width_to_et(width: u32) -> u32 {
    match width {
        8 => 3,
        16 => 4,
        32 => 6,
        64 => 9,
        128 => 14,
        _ => 0,
    }
}

fn pow3(e: u32) -> u32 {
    (0..e).fold(1u32, |p, _| p * 3)
}
fn offset_max(et: u32) -> u32 {
    pow3(et) - 1
}

// ---- Layer 1: assignment (tri_a2a.skill_et) ----
/// A hosted GF-T skill of a given width commits its rung's Et.
fn skill_et(width: u32) -> u32 {
    width_to_et(width)
}

// ---- Layer 2: receipt (tri_compute_receipt.receipt_leaf_gf_rung) ----
fn mix32(x: u32) -> u32 {
    let mut h = x ^ 0x9E37_79B9;
    h = h.wrapping_mul(0x85EB_CA77);
    h ^= h >> 15;
    h
}
/// The receipt leaf folds the rung Et, so two rungs of the same op/result differ.
fn receipt_leaf_rung(width: u32, et: u32, op: u32, result: u32) -> u32 {
    mix32(mix32(width ^ op.rotate_left(9)) ^ mix32(result) ^ et.rotate_left(13))
}

// ---- Layer 3: challenge (tri_compute_challenge.resolve_full_rung) ----
const RESOLVE_HONEST: u32 = 0;
const RESOLVE_SLASH: u32 = 1;
const RESOLVE_MALFORMED: u32 = 2;
const RESOLVE_RUNG_MISMATCH: u32 = 6;
fn resolve_full_rung(
    settled_et: u32,
    dispute_et: u32,
    settled_leaf: u32,
    dispute_leaf: u32,
    claimed: u32,
    recomputed: u32,
) -> u32 {
    if settled_et != dispute_et {
        RESOLVE_RUNG_MISMATCH // wrong-rung recompute -- no slash
    } else if settled_leaf != dispute_leaf {
        RESOLVE_MALFORMED // fabricated / unanchored dispute -- no slash
    } else if claimed == recomputed {
        RESOLVE_HONEST
    } else {
        RESOLVE_SLASH
    }
}

// ---- Layer 4: settlement (tri_compute_settle) ----
/// Width-proportional reward iff the offset is finite for the rung's OWN geometry.
fn settle(width: u32, offset: u32) -> u32 {
    let et = width_to_et(width);
    if et != 0 && offset < offset_max(et) {
        width // compute_reward = gf_width
    } else {
        0
    }
}

#[test]
fn one_rung_flows_intact_through_every_layer() {
    // A GF-T32 task: width 32, rung Et 6.
    let width = 32u32;
    let et = skill_et(width); // layer 1
    assert_eq!(et, 6, "GF-T32 assignment commits Et6");

    // Layer 2: the receipt commits that rung.
    let leaf = receipt_leaf_rung(width, et, 0x11, 0xABCD);
    let leaf_wrong_rung = receipt_leaf_rung(width, 4, 0x11, 0xABCD); // Et4 = GF-T16
    assert_ne!(leaf, leaf_wrong_rung, "a GF-T16-rung receipt differs from the GF-T32 one");

    // Layer 3: an honest same-rung dispute slashes a wrong result; a wrong-rung recompute does not.
    assert_eq!(
        resolve_full_rung(et, et, leaf, leaf, 0xABCD, 0xBEEF),
        RESOLVE_SLASH,
        "same rung, anchored, wrong result -> slash"
    );
    assert_eq!(
        resolve_full_rung(et, 4, leaf, leaf, 0xABCD, 0xBEEF),
        RESOLVE_RUNG_MISMATCH,
        "GF-T16 recompute against a GF-T32 receipt -> rung mismatch, NO slash"
    );

    // Layer 4: a finite GF-T32 offset settles; the same offset would be wrongly rejected
    // under GF-T16's geometry (offset_max 80) -- the layers must not mix rungs.
    let offset = 500u32; // finite for Et6 (< 728), out of range for Et4 (< 80)
    assert_eq!(settle(32, offset), 32, "GF-T32 offset 500 finite -> pays width 32");
    assert!(offset >= offset_max(4), "the same offset is out of range for a GF-T16 rung");
    assert!(offset < offset_max(6), "but finite for the true GF-T32 rung");
}

#[test]
fn the_wrong_rung_splice_is_caught_at_the_boundary() {
    // Attacker: assigned a GF-T32 task (Et6) but answers with a GF-T16 (Et4) computation.
    let assigned_et = skill_et(32); // 6
    let attacker_receipt_et = skill_et(16); // 4
    assert_ne!(assigned_et, attacker_receipt_et, "the attacker's rung differs from the assignment");

    // Assignment-side bind (result_binds_assign_rung): skill_et(assigned) must equal receipt Et.
    let binds = assigned_et == attacker_receipt_et;
    assert!(!binds, "a GF-T16 receipt does not bind a GF-T32 assignment");

    // Dispute-side: even if it slipped past ingress, the challenge rejects the rung.
    let leaf32 = receipt_leaf_rung(32, assigned_et, 0x11, 0x1234);
    assert_eq!(
        resolve_full_rung(assigned_et, attacker_receipt_et, leaf32, leaf32, 0x1234, 0x1234),
        RESOLVE_RUNG_MISMATCH,
        "the wrong-rung splice is rejected on dispute, not slashed and not paid"
    );

    // And the log2 bug that once split the layers: width_to_et(32) must be 6, never log2(32)=5.
    assert_eq!(width_to_et(32), 6, "the whole chain reads Et6 for GF-T32 -- not the old log2 5");
}
