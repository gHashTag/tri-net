//! trinet_a2a_node -- A2A-over-mesh path, composed from the generated spec modules.
//!
//! An A2A message rides KIND_DATA on A2A_PORT, sealed (crypto_frame), routed by TTL
//! (router_ttl); a relay forwards without parsing (payload is ciphertext), the
//! endpoint parses the fixed wire header (tri_a2a_wire) and enforces the format
//! family (tri_a2a). The endpoint then runs the HARDENED settle path: it recomputes
//! the receipt's 256-bit digest (tri_compute_receipt.digest_pre + tri_sha256),
//! verifies the executor's Ed25519 signature over it, settles ONLY on a valid
//! signature (settle_signed), and advances the 256-bit audited ledger head
//! (ledger_entry_pre + sha256_compress). All business logic is generated from
//! specs/*.t27 (Golden Pipeline); this binary is thin wiring.
#![allow(dead_code, unused)]

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey, Signature};

#[path = "../../gen/rust/tri_a2a.rs"]
mod a2a;
#[path = "../../gen/rust/tri_a2a_wire.rs"]
mod wire;
#[path = "../../gen/rust/router_ttl.rs"]
mod router;
#[path = "../../gen/rust/crypto_frame.rs"]
mod crypto;
#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_compute_settle.rs"]
mod settle;

fn digest256(req: u32, dev: u32, exe: u32, task: u32, inh: u32, out: u32, epoch: u32, prev: u32) -> [u32; 8] {
    let w = |i: u32| receipt::digest_pre(i, req, dev, exe, task, inh, out, epoch, prev);
    let mut d = [0u32; 8];
    let mut j = 0u32;
    while j < 8 {
        d[j as usize] = sha::sha256_word(
            w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7),
            w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), j,
        );
        j += 1;
    }
    d
}

fn ledger_head256(prev: &[u32; 8], dg: &[u32; 8], balance: u32, epoch: u32) -> [u32; 8] {
    let w = |i: u32| receipt::ledger_entry_pre(
        i, prev[0], prev[1], prev[2], prev[3], prev[4], prev[5], prev[6], prev[7],
        dg[0], dg[1], dg[2], dg[3], dg[4], dg[5], dg[6], dg[7], balance, epoch,
    );
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 {
        s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k);
        k += 1;
    }
    let mut head = [0u32; 8];
    let mut j = 0u32;
    while j < 8 {
        head[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j);
        j += 1;
    }
    head
}

fn digest_bytes(d: &[u32; 8]) -> [u8; 32] {
    let mut b = [0u8; 32];
    for i in 0..8 { b[i * 4..i * 4 + 4].copy_from_slice(&d[i].to_be_bytes()); }
    b
}
fn sig_ok(vk: &VerifyingKey, msg: &[u8; 32], sig: &Signature) -> u32 {
    if vk.verify(msg, sig).is_ok() { 1 } else { 0 }
}

fn main() {
    let (me, dst, from) = (0x0Au32, 0x0Cu32, 0x08u32);
    let (kind_data, ttl) = (1u32, 8u32);

    // 1. Demux by PORT: A2A rides KIND_DATA on A2A_PORT (relay & endpoint).
    assert!(a2a::is_a2a(kind_data, a2a::A2A_PORT));
    assert!(!a2a::is_a2a(0, a2a::A2A_PORT));

    // 2. RELAY forwards toward dst WITHOUT parsing (payload is sealed ciphertext).
    let relay = router::forward_decision(dst, me, ttl, 1, 0x0B, from);
    assert_eq!(relay, router::DECIDE_FORWARD);
    let receipt_body = 36usize; // 9 x u32 digest-preimage fields
    let sealed_len = crypto::HEADER_LEN + (wire::signed_result_len(receipt_body as u32) as usize) + crypto::TAG_LEN;
    assert!(crypto::frame_len_ok(sealed_len));

    // 3. ENDPOINT (dst == me): hand up locally, decrypt, parse the wire header.
    let endpoint = router::forward_decision(me, me, ttl, 1, 0x0B, from);
    assert_eq!(endpoint, router::DECIDE_LOCAL);
    let task = wire::task_id(0x00, 0x00, 0x20, 0x01);
    let skill = wire::skill_id(0xA6, 0x11); // GF-T16 mul
    assert!(wire::class_valid(wire::MSG_TASK_RESULT));
    assert!(wire::body_has_receipt(wire::MSG_TASK_RESULT) && wire::body_has_signature(wire::MSG_TASK_RESULT));

    // 4. Enforce format family; VERIFY the executor's Ed25519 signature over the
    //    256-bit receipt digest; settle ONLY on a valid signature; advance the
    //    256-bit audited ledger head that commits the settled balance.
    assert_eq!(a2a::skill_family(skill), a2a::FMT_GFT);
    assert_eq!(a2a::skill_op(skill), 0x11); // op agrees with receipt GF_MUL

    let (dev, exe, gfop, inh, out, epoch) = (0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0xABCDu32, 0x4100u32, 1u32);
    let d = digest256(task, dev, exe, gfop, inh, out, epoch, receipt::RECEIPT_GENESIS);

    // The executor signs the digest; the endpoint verifies before settling.
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let sig = sk.sign(&digest_bytes(&d));
    let ok = sig_ok(&vk, &digest_bytes(&d), &sig);
    assert_eq!(ok, 1, "honest result verifies");
    let bal = settle::settle_signed(1000, 16, 1, out, 6, 9, 0, ok);
    assert_eq!(bal, 1016, "valid signature + fresh + finite settles");

    let genesis = [receipt::LEDGER_GENESIS, 0, 0, 0, 0, 0, 0, 0];
    let head = ledger_head256(&genesis, &d, bal, epoch);

    // A forged result (tampered output, executor's old signature) is rejected here,
    // at the endpoint, before any payout -- the composed node enforces authenticity.
    let d_forge = digest256(task, dev, exe, gfop, inh, 0x9999, epoch, receipt::RECEIPT_GENESIS);
    let ok_forge = sig_ok(&vk, &digest_bytes(&d_forge), &sig);
    let bal_forge = settle::settle_signed(1000, 16, 1, 0x9999, 6, 9, 0, ok_forge);
    assert_eq!(bal_forge, 1000, "a forged result earns nothing at the endpoint");

    println!("A2A-over-mesh node (hardened): demux(port) OK  relay=FORWARD  endpoint=LOCAL  sealed_len={}", sealed_len);
    println!("  parse: task={:#06x} skill={:#06x}(GF-T16 mul) taskResult+receipt+signature family=GF-T", task, skill);
    println!("  digest={:08x}..{:08x}  sig_ok={}  settle 1000 -> {}", d[0], d[7], ok, bal);
    println!("  ledger head={:08x}..{:08x} (256-bit, commits the balance)", head[0], head[7]);
    println!("  forged result: sig_ok={} -> settle stays 1000 (rejected at endpoint)", ok_forge);
    println!("OK: hardened path -- digest_pre + tri_sha256 + Ed25519 verify + settle_signed + 256-bit head, all from specs");
}
