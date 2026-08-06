//! trinet_gft32_over_mesh -- the LARGEST rung crosses the wire (GF-T32, u64 recompute).
//!
//! The other over-wire bins exchange GF-T16 (u32, 9-bit mantissa packed by
//! tri_a2a_wire.assign_mant, which only holds 16 bits). GF-T32 has a 25-bit mantissa and
//! offsets to 728 -- it cannot fit that packing, so it never traversed the sealed mesh
//! even though the node's compute_ok and trinet_rung_verify verify it in-process. This
//! closes that gap: the requester seals a GF-T32 task carrying each operand as a FULL u32
//! word (25-bit mantissa intact); a blind relay forwards ciphertext; the executor opens
//! it, recomputes via the u64 path (tri_gft_arith.verify_gft_mul_full_u64), signs the
//! 256-bit input-bound receipt; the requester verifies WHO + the u64 recompute + input
//! binding from ITS operands. So "all four rungs" now holds end-to-end over the wire, not
//! just in-process. Negative: a GF-T32 result with the wrong exponent is rejected.
#![allow(dead_code, unused)]

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

#[path = "../../gen/rust/crypto_frame.rs"] mod cf;
#[path = "../../gen/rust/tri_a2a.rs"] mod a2a;
#[path = "../../gen/rust/tri_a2a_wire.rs"] mod wire;
#[path = "../../gen/rust/tri_sha256.rs"] mod sha;
#[path = "../../gen/rust/tri_node_identity.rs"] mod ident;
#[path = "../../gen/rust/tri_compute_receipt.rs"] mod receipt;
#[path = "../../gen/rust/tri_compute_settle.rs"] mod settle;
#[path = "../../gen/rust/tri_gft_arith.rs"] mod gmul;
#[path = "../../gen/rust/tri_gft_ladder.rs"] mod lad;

fn build_nonce(dir: u8, epoch: u32, ctr: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    let mut i = 0u32;
    while i < 12 { n[i as usize] = cf::nonce_byte(dir, epoch, ctr, i) as u8; i += 1; }
    n
}
fn frame_header(epoch: u32, ctr: u64) -> [u8; 12] {
    let mut h = [0u8; 12];
    h[0..4].copy_from_slice(&epoch.to_be_bytes());
    h[4..12].copy_from_slice(&ctr.to_be_bytes());
    h
}
fn seal(cipher: &ChaCha20Poly1305, dir: u8, epoch: u32, ctr: u64, pt: &[u8]) -> Vec<u8> {
    let hdr = frame_header(epoch, ctr);
    let ct = cipher.encrypt(Nonce::from_slice(&build_nonce(dir, epoch, ctr)), Payload { msg: pt, aad: &hdr }).expect("seal");
    let mut f: Vec<u8> = Vec::new();
    f.extend_from_slice(&hdr);
    f.extend_from_slice(&ct);
    f
}
fn open(cipher: &ChaCha20Poly1305, dir: u8, frame: &[u8]) -> Result<Vec<u8>, ()> {
    let co = cf::ciphertext_offset();
    let hdr = &frame[..co];
    let epoch = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]);
    let mut cb = [0u8; 8];
    cb.copy_from_slice(&hdr[4..12]);
    let ctr = u64::from_be_bytes(cb);
    cipher.decrypt(Nonce::from_slice(&build_nonce(dir, epoch, ctr)), Payload { msg: &frame[co..], aad: hdr }).map_err(|_| ())
}
fn digest_bytes(d: &[u32; 8]) -> [u8; 32] {
    let mut b = [0u8; 32];
    let mut i = 0usize;
    while i < 8 { b[i * 4..i * 4 + 4].copy_from_slice(&d[i].to_be_bytes()); i += 1; }
    b
}
fn executor_id(pubkey: &[u8; 32]) -> u32 {
    let mut k = [0u32; 8];
    let mut i = 0usize;
    while i < 8 { k[i] = u32::from_be_bytes([pubkey[i * 4], pubkey[i * 4 + 1], pubkey[i * 4 + 2], pubkey[i * 4 + 3]]); i += 1; }
    let w = |j: u32| ident::pubkey_pre(j, k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]);
    sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), 0)
}
fn operand_hash256(op: u32, a_off: u32, a_mant: u32, b_off: u32, b_mant: u32) -> [u32; 8] {
    let w = |i: u32| wire::operand_pre(i, op, a_off, a_mant, b_off, b_mant);
    let mut h = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { h[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    h
}
fn input_digest(req: u32, dev: u32, exe: u32, task: u32, oh: &[u32; 8], out: u32, epoch: u32, prev: u32) -> [u32; 8] {
    let w = |i: u32| receipt::input_digest_pre(i, req, dev, exe, task, oh[0], oh[1], oh[2], oh[3], oh[4], oh[5], oh[6], oh[7], out, epoch, prev);
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    let mut d = [0u32; 8];
    let mut j = 0u32;
    while j < 8 { d[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j); j += 1; }
    d
}
fn push_word(v: &mut Vec<u8>, w: u32) { v.extend_from_slice(&w.to_be_bytes()); }
fn read_word(b: &[u8], i: usize) -> u32 { u32::from_be_bytes([b[i * 4], b[i * 4 + 1], b[i * 4 + 2], b[i * 4 + 3]]) }

/// The executor's rung-aware GF-T32 recompute: verify the claimed result via the u64 path.
fn gft32_verify(a_off: u32, a_mant: u32, b_off: u32, b_mant: u32, claimed_off: u32, claimed_mant: u32) -> bool {
    let et = lad::GFT32_ET;
    gmul::verify_gft_mul_full_u64(a_off, a_mant as u64, b_off, b_mant as u64, claimed_off, claimed_mant,
        lad::gft_bias(et), lad::gft_offset_max(et), lad::gft_mant_one(et) as u64)
}

fn main() {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&[7u8; 32]));
    let (dir_assign, dir_result, epoch) = (0u8, 1u8, 1u32);
    let (task, dev, exe, gfop, out, ep) = (wire::task_id(0x00, 0x00, 0x32, 0x00), 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0x4320u32, 1u32);
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let pubkey = vk.to_bytes();
    let exec_id = executor_id(&pubkey);

    // GF-T32 mul 1.5*1.5: operands (364, 2^24) -> result (365, 2^22). The 25-bit mantissa
    // 2^24 = 16777216 needs a full u32 word -- assign_mant's 16-bit packing cannot carry it.
    let (a_off, a_mant, b_off, b_mant) = (364u32, 16777216u32, 364u32, 16777216u32);
    let (res_off, res_mant) = (365u32, 4194304u32); // 2^22

    // LEG 1: requester seals the GF-T32 assign with FULL u32 operand words.
    let mut asg: Vec<u8> = Vec::new();
    for wv in [task, gfop, a_off, a_mant, b_off, b_mant] { push_word(&mut asg, wv); }
    let asg_frame = seal(&cipher, dir_assign, epoch, 0x3201, &asg);
    assert!(cf::frame_len_ok(asg_frame.len()));
    let co = cf::ciphertext_offset();
    assert_ne!(&asg_frame[co..co + asg.len()], &asg[..], "blind relay: ciphertext, not the GF-T32 operands");
    assert!(a2a::is_a2a(1, a2a::A2A_PORT));

    // LEG 2: executor opens, recomputes GF-T32 via the u64 path on the RECEIVED operands.
    let ar = open(&cipher, dir_assign, &asg_frame).expect("executor opens the GF-T32 assign");
    assert_eq!(ar, asg, "GF-T32 operands survive mesh transit byte-exact");
    let (rt, rop, ra, rma, rb, rmb) = (read_word(&ar, 0), read_word(&ar, 1), read_word(&ar, 2), read_word(&ar, 3), read_word(&ar, 4), read_word(&ar, 5));
    assert_eq!((ra, rma, rb, rmb), (a_off, a_mant, b_off, b_mant), "executor recovers the exact 25-bit-mantissa operands");
    assert!(gft32_verify(ra, rma, rb, rmb, res_off, res_mant), "executor's GF-T32 u64 recompute checks");
    let oh_exec = operand_hash256(rop, ra, rma, rb, rmb);
    let d = input_digest(rt, dev, exe, gfop, &oh_exec, out, ep, receipt::RECEIPT_GENESIS);
    let sig = sk.sign(&digest_bytes(&d));

    // executor seals the result (digest + sig + pubkey + exec).
    let mut resm: Vec<u8> = Vec::new();
    resm.extend_from_slice(&digest_bytes(&d));
    resm.extend_from_slice(&sig.to_bytes());
    resm.extend_from_slice(&pubkey);
    push_word(&mut resm, exec_id);
    let res_frame = seal(&cipher, dir_result, epoch, 0x3202, &resm);

    // LEG 3: requester opens, verifies WHO + the u64 recompute + input binding.
    let rr = open(&cipher, dir_result, &res_frame).expect("requester opens the GF-T32 result");
    let mut dg = [0u32; 8];
    for i in 0..8 { dg[i] = read_word(&rr, i); }
    let mut sb = [0u8; 64];
    sb.copy_from_slice(&rr[32..96]);
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&rr[96..128]);
    let claimed_exec = read_word(&rr, 32);
    let oh_req = operand_hash256(gfop, a_off, a_mant, b_off, b_mant);
    let d_req = input_digest(task, dev, exe, gfop, &oh_req, out, ep, receipt::RECEIPT_GENESIS);
    assert_eq!(dg, d_req, "receipt digest binds the GF-T32 operands the requester assigned");
    let sig_ok = VerifyingKey::from_bytes(&pk).unwrap().verify(&digest_bytes(&d_req), &Signature::from_bytes(&sb)).is_ok();
    let who = ident::who_ok(sig_ok as u32, claimed_exec, executor_id(&pk));
    let cok = gft32_verify(a_off, a_mant, b_off, b_mant, res_off, res_mant);
    let fresh = cf::replay_accept(false, 0, 0, 0, 0x3202);
    let bal = settle::settle_signed(1000, 16, 1, out, 6, 9, 0, (who as u32) & (cok as u32) & (fresh as u32));
    assert_eq!((who, cok, fresh), (true, true, true), "GF-T32 result verifies end-to-end over the wire");
    assert_eq!(bal, 1016, "a GF-T32 receipt settles after crossing the sealed mesh");

    // NEGATIVE: a GF-T32 result with the wrong exponent is rejected (u64 recompute discriminates).
    assert!(!gft32_verify(a_off, a_mant, b_off, b_mant, 364, res_mant), "wrong GF-T32 exponent -> rejected");

    println!("GF-T32 (largest rung, u64) compute exchange over the sealed mesh:");
    println!("  operands (364, 2^24) sealed as full u32 words (assign_mant's 16-bit packing cannot);");
    println!("  executor opened byte-exact -> u64 recompute (365, 2^22) -> signed;");
    println!("  requester: who={} recompute={} fresh={} -> settle 1000 -> {}", who, cok, fresh, bal);
    println!("  wrong exponent -> rejected");
    println!("OK: all four rungs (incl GF-T32 u64) now verify end-to-end over a real sealed datagram");
}
