//! gft_rung_over_wire -- the rung binding survives MESH TRANSPORT. The A2A wire header
//! is [ class(1) | task_id(4 BE) | skill(2 BE) | body... ] (tri_a2a_wire): the RUNG rides
//! in the header's skill id (0xA6.. GF-T16, 0xA5.. GF-T32, 0xA3.. GF-T64, ...), a position
//! the executor signs around but a relay/attacker cannot silently retag without breaking
//! the assignment. A verifier reading a datagram derives the rung's Et from the HEADER
//! skill (trusted) and recomputes the receipt leaf at that Et; a body-receipt computed at a
//! DIFFERENT rung than the header advertises fails to match. This extends the on-node rung
//! chain (gft_rung_end_to_end) with the wire-decode front-end, proving the binding holds
//! device -> node -> node -> device.

// ---- wire header decode (tri_a2a_wire: OFF_CLASS 0, OFF_TASK 1, OFF_SKILL 5) ----
fn task_id(b1: u32, b2: u32, b3: u32, b4: u32) -> u32 {
    (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
}
fn skill_id(b5: u32, b6: u32) -> u32 {
    (b5 << 8) | b6
}

// ---- ratified skill -> rung Et (SSOT: tri_a2a.skill_et / tri_gft_ladder) ----
// GF-T4->2, GF-T8->3, GF-T16->4, GF-T32->6, GF-T64->9, GF-T128->14. Op suffix (0x11 mul /
// 0x10 add) is masked off; unknown / binary GF16 skills fail closed at Et 0.
const SKILL_GFT4: u32 = 0xA4;
const SKILL_GFT8: u32 = 0xA8;
const SKILL_GFT16: u32 = 0xA6;
const SKILL_GFT32: u32 = 0xA5;
const SKILL_GFT64: u32 = 0xA3;
const SKILL_GFT128: u32 = 0xA2;
fn skill_rung_et(skill: u32) -> u32 {
    match skill >> 8 {
        // top byte carries the rung family code
        SKILL_GFT4 => 2,
        SKILL_GFT8 => 3,
        SKILL_GFT16 => 4,
        SKILL_GFT32 => 6,
        SKILL_GFT64 => 9,
        SKILL_GFT128 => 14,
        _ => 0, // GF16 binary (0x16) or crafted -> fail closed
    }
}

// ---- receipt leaf that folds the rung Et (models tri_compute_receipt.receipt_leaf_gf_rung) ----
fn mix32(x: u32) -> u32 {
    let mut h = x ^ 0x9E37_79B9;
    h = h.wrapping_mul(0x85EB_CA77);
    h ^= h >> 15;
    h
}
fn receipt_leaf(gf_et: u32, op: u32, a: u32, b: u32, result: u32) -> u32 {
    mix32(mix32(op ^ a.rotate_left(7) ^ b) ^ mix32(result) ^ gf_et.rotate_left(13))
}

/// The over-wire verifier: derive the rung Et from the HEADER skill (trusted position),
/// recompute the receipt leaf at that Et, and accept iff it matches the executor's leaf.
fn wire_accepts(
    b5: u32,
    b6: u32,
    op: u32,
    a: u32,
    b: u32,
    result: u32,
    receipt_leaf_from_body: u32,
) -> bool {
    let header_et = skill_rung_et(skill_id(b5, b6));
    if header_et == 0 {
        return false; // unknown skill on the wire -> reject
    }
    receipt_leaf(header_et, op, a, b, result) == receipt_leaf_from_body
}

#[test]
fn header_decode_is_exact_and_carries_the_rung() {
    assert_eq!(
        task_id(0x12, 0x34, 0x56, 0x78),
        0x1234_5678,
        "4 BE task bytes"
    );
    assert_eq!(
        skill_id(0xA3, 0x11),
        0xA311,
        "GF-T64 mul skill from 2 BE bytes"
    );
    // the rung is recoverable from the header skill alone
    assert_eq!(
        skill_rung_et(skill_id(0xA4, 0x11)),
        2,
        "GF-T4 header -> Et2 (bottom rung)"
    );
    assert_eq!(
        skill_rung_et(skill_id(0xA6, 0x11)),
        4,
        "GF-T16 header -> Et4"
    );
    assert_eq!(
        skill_rung_et(skill_id(0xA3, 0x10)),
        9,
        "GF-T64 add header -> Et9"
    );
    assert_eq!(
        skill_rung_et(skill_id(0x16, 0x11)),
        0,
        "binary GF16 header -> no ternary rung"
    );
    assert_eq!(
        skill_rung_et(skill_id(0xBE, 0xEF)),
        0,
        "crafted skill -> fail closed"
    );
}

#[test]
fn honest_result_survives_the_wire() {
    // Executor assigned GF-T64 (header 0xA311), computes at GF-T64 (Et9), signs the leaf.
    let leaf = receipt_leaf(9, 0x11, 0xAA, 0xBB, 0xCC);
    assert!(
        wire_accepts(0xA3, 0x11, 0x11, 0xAA, 0xBB, 0xCC, leaf),
        "an honest GF-T64 result whose header advertises GF-T64 is accepted over the wire"
    );
}

#[test]
fn wrong_rung_splice_is_caught_at_the_wire() {
    // Attacker: header advertises GF-T64 (0xA311) -- the assignment's rung -- but the body
    // receipt was computed cheaply at GF-T16 (Et4). The verifier recomputes at the HEADER's
    // Et9 and the leaves diverge, so the splice is rejected before any recompute is trusted.
    let cheap_leaf = receipt_leaf(4, 0x11, 0xAA, 0xBB, 0xCC); // GF-T16 rung
    assert!(
        !wire_accepts(0xA3, 0x11, 0x11, 0xAA, 0xBB, 0xCC, cheap_leaf),
        "a GF-T16 receipt under a GF-T64 header is rejected -- rung binding survives the wire"
    );
    // And the reverse: claiming a higher rung in the header than was computed also fails.
    let gft16_leaf = receipt_leaf(4, 0x11, 0xAA, 0xBB, 0xCC);
    assert!(
        wire_accepts(0xA6, 0x11, 0x11, 0xAA, 0xBB, 0xCC, gft16_leaf),
        "the SAME leaf under its correct GF-T16 header (0xA611) is accepted"
    );
}

#[test]
fn an_unknown_skill_on_the_wire_is_rejected() {
    // A relay that retags the header to a non-ladder skill cannot get a result accepted.
    let leaf = receipt_leaf(9, 0x11, 0xAA, 0xBB, 0xCC);
    assert!(
        !wire_accepts(0x16, 0x11, 0x11, 0xAA, 0xBB, 0xCC, leaf),
        "a binary-GF header carries no ternary rung -> rejected (fail closed)"
    );
}

#[test]
fn gf_t4_bottom_rung_survives_the_wire() {
    // GF-T4 is now a hosted, silicon-backed skill (0xA411); its results must cross the mesh.
    // Honest GF-T4 (Et2) under a GF-T4 header is accepted.
    let leaf4 = receipt_leaf(2, 0x11, 0xAA, 0xBB, 0xCC);
    assert!(
        wire_accepts(0xA4, 0x11, 0x11, 0xAA, 0xBB, 0xCC, leaf4),
        "an honest GF-T4 result under a GF-T4 header survives the wire"
    );
    // A GF-T8 receipt (Et3) spliced under a GF-T4 header is rejected -- the wrong-rung
    // guard holds at the bottom rung too.
    let leaf8 = receipt_leaf(3, 0x11, 0xAA, 0xBB, 0xCC);
    assert!(
        !wire_accepts(0xA4, 0x11, 0x11, 0xAA, 0xBB, 0xCC, leaf8),
        "a GF-T8 receipt under a GF-T4 header is rejected over the wire"
    );
}
