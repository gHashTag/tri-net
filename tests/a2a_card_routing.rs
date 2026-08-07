//! a2a_card_routing -- CI guard for the A2A agent-card ROUTING layer (specs/tri_a2a_card.t27), the
//! outward ring layer that decides whether a host can serve a task's (format-family, width, op). It
//! has 8 spec tests but no CI twin, and it is correctness-critical: a mis-decode silently routes a
//! GF-T64 task to a GF-T16 or binary-GF host that cannot compute it. The spec documents the exact bug
//! this fixed (#242/#243): GF-T32/64/128 were once mis-classed as binary width-16. This transcribes
//! the card functions and pins the whole-ladder decode, the AND-of-both-masks routing, the op
//! advertisement, and -- as a regression -- the mis-route the fix closed.

const FMT_GF_BINARY: u32 = 0;
const FMT_GFT: u32 = 1;
const GF_OP_ADD: u32 = 0x10;
const GF_OP_MUL: u32 = 0x11;

fn family_bit(family: u32) -> u32 {
    1 << family
}
fn make_card(family_mask: u32, width_mask: u32) -> u32 {
    (family_mask << 16) | (width_mask & 0xFFFF)
}
fn make_card_ops(family_mask: u32, width_mask: u32, op_mask: u32) -> u32 {
    (op_mask << 24) | (family_mask << 16) | (width_mask & 0xFFFF)
}
fn card_families(card: u32) -> u32 {
    card >> 16
}
fn card_widths(card: u32) -> u32 {
    card & 0xFFFF
}
fn card_ops(card: u32) -> u32 {
    (card >> 24) & 0xFF
}
fn hosts_family(card: u32, family: u32) -> bool {
    (card_families(card) & family_bit(family)) != 0
}
fn hosts_width(card: u32, width: u32) -> bool {
    (card_widths(card) & width) != 0
}
fn op_bit(op: u32) -> u32 {
    1 << (op & 0xF)
}
fn hosts_op(card: u32, op: u32) -> bool {
    (card_ops(card) & op_bit(op)) != 0
}
fn can_serve(card: u32, family: u32, width: u32) -> bool {
    hosts_family(card, family) && hosts_width(card, width)
}
fn can_serve_op(card: u32, family: u32, width: u32, op: u32) -> bool {
    can_serve(card, family, width) && hosts_op(card, op)
}

fn skill_hi(skill: u32) -> u32 {
    (skill >> 8) & 0xFF
}
fn skill_card_family(skill: u32) -> u32 {
    match skill_hi(skill) {
        0xA4 | 0xA8 | 0xA6 | 0xA5 | 0xA3 | 0xA2 => FMT_GFT, // GF-T4/8/16/32/64/128
        _ => FMT_GF_BINARY,
    }
}
fn skill_card_width(skill: u32) -> u32 {
    match skill_hi(skill) {
        0xA4 => 4,
        0xA8 => 8,
        0xA5 => 32,
        0xA3 => 64,
        0xA2 => 128,
        _ => 16, // GF-T16 (0xA6) and binary GF16 (0x16) both width 16
    }
}
fn skill_op_suffix(skill: u32) -> u32 {
    skill & 0xFF
}
fn can_serve_skill(card: u32, skill: u32) -> bool {
    can_serve(card, skill_card_family(skill), skill_card_width(skill))
}
fn can_serve_skill_op(card: u32, skill: u32) -> bool {
    can_serve_skill(card, skill) && hosts_op(card, skill_op_suffix(skill))
}

// The ratified ladder: (mul-skill-id, expected family, expected width).
const LADDER: [(u32, u32, u32); 7] = [
    (0xA411, FMT_GFT, 4),
    (0xA811, FMT_GFT, 8),
    (0xA611, FMT_GFT, 16),
    (0xA511, FMT_GFT, 32),
    (0xA311, FMT_GFT, 64),
    (0xA211, FMT_GFT, 128),
    (0x1611, FMT_GF_BINARY, 16), // binary GF16
];

#[test]
fn every_ladder_rung_decodes_to_its_family_and_width() {
    for (skill, fam, width) in LADDER {
        assert_eq!(
            skill_card_family(skill),
            fam,
            "family decode for skill {skill:#x}"
        );
        assert_eq!(
            skill_card_width(skill),
            width,
            "width decode for skill {skill:#x}"
        );
    }
}

#[test]
fn a_full_ladder_gft_host_serves_every_gft_rung_and_no_binary() {
    let full = make_card(family_bit(FMT_GFT), 4 | 8 | 16 | 32 | 64 | 128);
    for (skill, fam, _) in LADDER {
        let expect = fam == FMT_GFT; // GF-T rungs served; the binary GF16 skill is not
        assert_eq!(
            can_serve_skill(full, skill),
            expect,
            "full GF-T host vs {skill:#x}"
        );
    }
}

#[test]
fn routing_needs_both_family_and_width() {
    let gft16 = make_card(family_bit(FMT_GFT), 16);
    assert!(can_serve(gft16, FMT_GFT, 16), "GF-T16 host serves GF-T16");
    assert!(
        !can_serve(gft16, FMT_GF_BINARY, 16),
        "wrong family rejected"
    );
    assert!(!can_serve(gft16, FMT_GFT, 8), "wrong width rejected");
}

#[test]
fn the_mis_route_the_fix_closed_stays_closed() {
    // Regression for #242/#243. A GF-T16-only host must reject a GF-T64 task (width), not silently
    // mis-route it; and a binary-GF host must reject a GF-T64 task (family) even if it advertises
    // width 64 -- because GF-T64 is now FMT_GFT/width-64, not the old mis-classed binary width-16.
    let gft16 = make_card(family_bit(FMT_GFT), 16);
    assert!(
        !can_serve_skill(gft16, 0xA311),
        "GF-T16-only host rejects GF-T64 (width)"
    );
    assert!(can_serve_skill(gft16, 0xA611), "but still serves GF-T16");
    let bin16 = make_card(family_bit(FMT_GF_BINARY), 16 | 64);
    assert!(
        !can_serve_skill(bin16, 0xA311),
        "binary host rejects GF-T64 (family), despite advertising width 64"
    );
    assert!(
        can_serve_skill(bin16, 0x1611),
        "binary GF16 still serves its own binary skill"
    );
}

#[test]
fn op_advertisement_gates_by_operation() {
    let mulonly = make_card_ops(family_bit(FMT_GFT), 16, op_bit(GF_OP_MUL));
    assert!(hosts_op(mulonly, GF_OP_MUL), "hosts mul");
    assert!(!hosts_op(mulonly, GF_OP_ADD), "does not host add");
    assert!(
        can_serve_op(mulonly, FMT_GFT, 16, GF_OP_MUL),
        "GF-T16 mul served"
    );
    assert!(
        !can_serve_op(mulonly, FMT_GFT, 16, GF_OP_ADD),
        "GF-T16 add rejected (op)"
    );
    assert!(
        !can_serve_op(mulonly, FMT_GF_BINARY, 16, GF_OP_MUL),
        "wrong family still rejected"
    );
}

#[test]
fn skill_op_routing_matches_op_family_and_width_together_across_the_ladder() {
    // A mul-only host on any rung takes that rung's mul (low byte 0x11) and rejects its add (0x10);
    // and a right-op-wrong-rung request is rejected. The op is read from the skill's low byte.
    for (mul_skill, _, width) in LADDER {
        let add_skill = (mul_skill & !0xFF) | 0x10; // same rung, ADD suffix
        let mulhost = make_card_ops(
            family_bit(skill_card_family(mul_skill)),
            width,
            op_bit(GF_OP_MUL),
        );
        assert!(
            can_serve_skill_op(mulhost, mul_skill),
            "mul-only host takes {mul_skill:#x}"
        );
        assert!(
            !can_serve_skill_op(mulhost, add_skill),
            "mul-only host rejects the add on the same rung"
        );
    }
    // A GF-T4-only host declines a GF-T64 mul (right op, wrong rung).
    let m4 = make_card_ops(
        family_bit(FMT_GFT),
        4,
        op_bit(GF_OP_MUL) | op_bit(GF_OP_ADD),
    );
    assert!(
        !can_serve_skill_op(m4, 0xA311),
        "GF-T4-only host rejects a GF-T64 mul (wrong rung)"
    );
}
