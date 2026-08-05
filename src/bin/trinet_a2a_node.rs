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
#[path = "../../gen/rust/tri_gft_arith.rs"]
mod gmul;
#[path = "../../gen/rust/tri_gft_add.rs"]
mod gadd;
#[path = "../../gen/rust/tri_gft_sub.rs"]
mod gsub;
#[path = "../../gen/rust/tri_receipt_verify.rs"]
mod rv;

/// Recompute the claimed GF-T result from the assigned operands and the op: the
/// endpoint checks the compute itself, not just the signature. Returns 1 if the
/// claimed (offset, mant) recomputes for the op, else 0.
fn compute_ok(gf_op: u32, sign_a: u32, sign_b: u32, oa: u32, ma: u32, ob: u32, mb: u32, claimed_off: u32, claimed_mant: u32) -> u32 {
    let mul = if gmul::verify_gft_mul_full(oa, ma, ob, mb, claimed_off, claimed_mant, gmul::GFT16_BIAS, gmul::GFT16_OFFSET_MAX) { 1u32 } else { 0 };
    let add = if sign_a == sign_b {
        if gadd::verify_gft_add(oa, ob, ma, mb, claimed_off, claimed_mant, gmul::GFT16_OFFSET_MAX) { 1u32 } else { 0 }
    } else {
        if gsub::verify_gft_sub(oa, ob, ma, mb, claimed_off, claimed_mant) { 1u32 } else { 0 }
    };
    rv::compute_ok_for_op(gf_op, mul, add)
}

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

    // The endpoint RECOMPUTES the compute from the assigned GF-T operands (parsed
    // from the taskAssign body, tri_a2a_wire) and only settles if the claimed result
    // recomputes -- a valid signature over a WRONG result is not enough. Here the
    // task is GF-T16 mul phi^1 * phi^1 = phi^2: operands (41,0) & (41,0), result (42,0).
    let (a_off, a_mant, b_off, b_mant) = (41u32, 0u32, 41u32, 0u32);
    let (claimed_off, claimed_mant) = (42u32, 0u32);
    let cok = compute_ok(gfop, 0, 0, a_off, a_mant, b_off, b_mant, claimed_off, claimed_mant);
    assert_eq!(cok, 1, "the claimed GF-T product recomputes");
    let bal = settle::settle_signed(1000, 16, 1, out, 6, 9, 0, ok & cok);
    assert_eq!(bal, 1016, "valid signature AND correct compute settles");

    let genesis = [receipt::LEDGER_GENESIS, 0, 0, 0, 0, 0, 0, 0];
    let head = ledger_head256(&genesis, &d, bal, epoch);

    // A forged result (tampered output, executor's old signature) is rejected here,
    // at the endpoint, before any payout -- the composed node enforces authenticity.
    let d_forge = digest256(task, dev, exe, gfop, inh, 0x9999, epoch, receipt::RECEIPT_GENESIS);
    let ok_forge = sig_ok(&vk, &digest_bytes(&d_forge), &sig);
    let bal_forge = settle::settle_signed(1000, 16, 1, 0x9999, 6, 9, 0, ok_forge);
    assert_eq!(bal_forge, 1000, "a forged result earns nothing at the endpoint");

    // A WRONG-COMPUTE result that is correctly signed: the operands are honest and
    // the signature verifies, but the claimed product exponent is wrong (43 not 42).
    // The recompute catches it -- signature is not correctness.
    let cok_bad = compute_ok(gfop, 0, 0, a_off, a_mant, b_off, b_mant, 43, 0);
    let bal_badcompute = settle::settle_signed(1000, 16, 1, out, 6, 9, 0, ok & cok_bad);
    assert_eq!((cok_bad, bal_badcompute), (0, 1000), "a signed but miscomputed result earns nothing");

    println!("A2A-over-mesh node (hardened + recompute): demux(port) OK  relay=FORWARD  endpoint=LOCAL  sealed_len={}", sealed_len);
    println!("  parse: task={:#06x} skill={:#06x}(GF-T16 mul) taskResult+receipt+signature family=GF-T", task, skill);
    println!("  digest={:08x}..{:08x}  sig_ok={}  compute_ok={}  settle 1000 -> {}", d[0], d[7], ok, cok, bal);
    println!("  ledger head={:08x}..{:08x} (256-bit, commits the balance)", head[0], head[7]);
    println!("  forged result:     sig_ok={} -> settle stays 1000 (rejected at endpoint)", ok_forge);
    println!("  signed but WRONG compute (claims phi^2=43): compute_ok={} -> settle stays 1000", cok_bad);
    println!("OK: endpoint enforces WHO (Ed25519) + CORRECTNESS (GF-T recompute) before settling; signature alone is not enough");
}
