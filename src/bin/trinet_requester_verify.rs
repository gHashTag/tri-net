//! trinet_requester_verify -- the requester round-trip: the party that SENT the
//! task (and therefore knows the operands) verifies the result before paying.
//!
//! The requester assigned (op, a, b). The executor returns a claimed result + a
//! receipt whose 256-bit input-bound digest (input_digest_pre over the FULL operand
//! hash) is signed. The requester recomputes: (1) the operand hash from ITS operands,
//! (2) the result via the op dispatch, (3) the input-bound digest, and accepts only
//! if the signature verifies over THAT digest AND the result recomputes. An executor
//! that computed over DIFFERENT operands is caught: its signed digest is over a
//! different operand hash, so the requester's recomputed digest no longer verifies.
#![allow(dead_code, unused)]

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey, Signature};

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_a2a_wire.rs"]
mod wire;
#[path = "../../gen/rust/tri_gft_arith.rs"]
mod gmul;
#[path = "../../gen/rust/tri_receipt_verify.rs"]
mod rv;

fn operand_hash(op: u32, ao: u32, am: u32, bo: u32, bm: u32) -> [u32; 8] {
    let w = |i: u32| wire::operand_pre(i, op, ao, am, bo, bm);
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
fn dbytes(d: &[u32; 8]) -> [u8; 32] { let mut b = [0u8; 32]; for i in 0..8 { b[i * 4..i * 4 + 4].copy_from_slice(&d[i].to_be_bytes()); } b }

fn main() {
    let sk = SigningKey::from_bytes(&[7u8; 32]); // executor's key
    let vk = sk.verifying_key();
    let (req, dev, exe, task, epoch, prev) = (0x2001u32, 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 1u32, receipt::RECEIPT_GENESIS);

    // Requester ASSIGNED: GF-T16 mul of a=(41,0), b=(41,0); expects (42,0).
    let (op, a_off, a_mant, b_off, b_mant) = (0x11u32, 41u32, 0u32, 41u32, 0u32);

    // Executor's honest response: computes over the assigned operands, signs the digest.
    let out = 42u32; // result offset (GF-T16 phi^2)
    let oh_exec = operand_hash(op, a_off, a_mant, b_off, b_mant);
    let d_exec = input_digest(req, dev, exe, task, &oh_exec, out, epoch, prev);
    let sig = sk.sign(&dbytes(&d_exec));

    // --- Requester verifies with ITS OWN operands (does not trust the executor). ---
    let oh_req = operand_hash(op, a_off, a_mant, b_off, b_mant);
    let d_req = input_digest(req, dev, exe, task, &oh_req, out, epoch, prev);
    let sig_ok = if vk.verify(&dbytes(&d_req), &sig).is_ok() { 1u32 } else { 0 };
    let mul = if gmul::verify_gft_mul_full(a_off, a_mant, b_off, b_mant, out, 0, gmul::GFT16_BIAS, gmul::GFT16_OFFSET_MAX) { 1u32 } else { 0 };
    let compute_ok = rv::compute_ok_for_op(op, mul, 0);
    let accept = rv::receipt_accepted(sig_ok, 1, compute_ok);
    assert!(accept, "honest round-trip accepted");

    // --- Attack: executor computed over DIFFERENT operands a'=(50,0) but returns the
    // same claimed out; it signs a digest over oh(a'). The requester verifies with the
    // operands IT assigned -> a different digest -> the signature does not verify. ---
    let oh_bad = operand_hash(op, 50, 0, b_off, b_mant);
    let d_bad = input_digest(req, dev, exe, task, &oh_bad, out, epoch, prev);
    let sig_bad = sk.sign(&dbytes(&d_bad));
    let sig_ok_bad = if vk.verify(&dbytes(&d_req), &sig_bad).is_ok() { 1u32 } else { 0 };
    assert_eq!(sig_ok_bad, 0, "a receipt for other operands fails the requester's input binding");

    // --- Attack: honest operands but WRONG claimed result (43 not 42). ---
    let mul_bad = if gmul::verify_gft_mul_full(a_off, a_mant, b_off, b_mant, 43, 0, gmul::GFT16_BIAS, gmul::GFT16_OFFSET_MAX) { 1u32 } else { 0 };
    let compute_bad = rv::compute_ok_for_op(op, mul_bad, 0);
    assert!(!rv::receipt_accepted(1, 1, compute_bad), "a wrong result is rejected by recompute");

    println!("requester round-trip verify (the sender knows the operands):");
    println!("  honest: sig_ok={} compute_ok={} -> accepted={}", sig_ok, compute_ok, accept);
    println!("  executor computed over OTHER operands (a=50 not 41) -> requester sig_ok={} (rejected)", sig_ok_bad);
    println!("  executor claims a WRONG result (43 not 42)          -> compute_ok=0 (rejected)");
    println!("OK: the requester binds inputs (256-bit) AND recomputes the result before paying");
}
