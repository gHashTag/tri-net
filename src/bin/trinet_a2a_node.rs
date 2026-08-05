//! trinet_a2a_node -- A2A-over-mesh path, composed from the generated spec modules.
//!
//! Moves the (previously Python-prototyped, then spec-composed) A2A-over-mesh flow
//! into the repo as a real binary: an A2A message rides KIND_DATA on A2A_PORT,
//! sealed (crypto_frame), routed by TTL (router_ttl); a relay forwards without
//! parsing (payload is ciphertext), the endpoint parses the fixed wire header
//! (tri_a2a_wire) and enforces the format family (tri_a2a) before the receipt /
//! settle path (tri_compute_receipt / tri_compute_settle). All business logic is
//! generated from specs/*.t27 (Golden Pipeline); this binary is thin wiring.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_a2a.rs"]
mod a2a;
#[path = "../../gen/rust/tri_a2a_wire.rs"]
mod wire;
#[path = "../../gen/rust/router_ttl.rs"]
mod router;
#[path = "../../gen/rust/crypto_frame.rs"]
mod crypto;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_compute_settle.rs"]
mod settle;

fn main() {
    let (me, dst, from) = (0x0Au32, 0x0Cu32, 0x08u32);
    let (kind_data, ttl) = (1u32, 8u32);

    // 1. Demux by PORT: A2A rides KIND_DATA on A2A_PORT (relay & endpoint).
    assert!(a2a::is_a2a(kind_data, a2a::A2A_PORT));
    assert!(!a2a::is_a2a(0, a2a::A2A_PORT));

    // 2. RELAY forwards toward dst WITHOUT parsing (payload is sealed ciphertext).
    let relay = router::forward_decision(dst, me, ttl, 1, 0x0B, from);
    assert_eq!(relay, router::DECIDE_FORWARD);
    let sealed_len = crypto::HEADER_LEN + (wire::HDR_LEN as usize) + 9 + crypto::TAG_LEN;
    assert!(crypto::frame_len_ok(sealed_len));

    // 3. ENDPOINT (dst == me): hand up locally, decrypt, parse the wire header.
    let endpoint = router::forward_decision(me, me, ttl, 1, 0x0B, from);
    assert_eq!(endpoint, router::DECIDE_LOCAL);
    let task = wire::task_id(0x00, 0x00, 0x20, 0x01);
    let skill = wire::skill_id(0xA6, 0x11); // GF-T16 mul
    assert!(wire::class_valid(wire::MSG_TASK_RESULT) && wire::body_has_receipt(wire::MSG_TASK_RESULT));

    // 4. Enforce format family, then bind + settle the compute receipt.
    assert_eq!(a2a::skill_family(skill), a2a::FMT_GFT);
    assert_eq!(a2a::skill_op(skill), 0x11); // op agrees with receipt GF_MUL
    let leaf = receipt::receipt_leaf_gf_fmt(
        receipt::FMT_GFT, receipt::GF16, receipt::GF_MUL,
        0x3F00, 0x4000, 0x4100, 0xC0FFEE01, 0xE0E0, 1,
    );
    let bal = settle::settle_full(1000, 16, 1, 0x4100, 6, 9, 0);

    println!("A2A-over-mesh node: demux(port) OK  relay=FORWARD  endpoint=LOCAL  sealed_len={}", sealed_len);
    println!("  parse: task={:#06x} skill={:#06x}(GF-T16 mul) taskResult+receipt family=GF-T", task, skill);
    println!("  receipt leaf={:#010x}  settle balance 1000 -> {}", leaf, bal);
    println!("OK: composed from generated specs (tri_a2a, tri_a2a_wire, router_ttl, crypto_frame, tri_compute_receipt, tri_compute_settle)");
}
