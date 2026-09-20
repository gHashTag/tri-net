//! trinet_receipt_verify -- the capstone: accept a compute receipt only if all
//! three independent checks pass -- WHO (Ed25519 signature over the 256-bit digest),
//! MEMBERSHIP (digest under the signed Merkle batch root), CORRECTNESS (the claimed
//! GF-T result recomputes). Composes the whole ring: tri_sha256 + digest_pre +
//! merkle_pair_pre + tri_gft_arith + tri_receipt_verify, with real Ed25519. Shows an
//! honest receipt accepted and each single failure rejected with its reason code.
#![allow(dead_code, unused)]

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey, Signature};

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_gft_arith.rs"]
mod gfa;
#[path = "../../gen/rust/tri_receipt_verify.rs"]
mod verify;

fn digest256(req: u32, dev: u32, exe: u32, task: u32, inh: u32, out: u32, epoch: u32, prev: u32) -> [u32; 8] {
    let w = |i: u32| receipt::digest_pre(i, req, dev, exe, task, inh, out, epoch, prev);
    let mut d = [0u32; 8];
    let mut j = 0u32;
    while j < 8 { d[j as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), j); j += 1; }
    d
}
fn pair256(l: &[u32; 8], r: &[u32; 8]) -> [u32; 8] {
    let w = |i: u32| receipt::merkle_pair_pre(i, l[0], l[1], l[2], l[3], l[4], l[5], l[6], l[7], r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    let mut o = [0u32; 8];
    let mut j = 0u32;
    while j < 8 { o[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j); j += 1; }
    o
}
fn dbytes(d: &[u32; 8]) -> [u8; 32] { let mut b = [0u8; 32]; for i in 0..8 { b[i * 4..i * 4 + 4].copy_from_slice(&d[i].to_be_bytes()); } b }

fn main() {
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();

    // A GF-T16 multiply receipt: phi^1 * phi^1 = phi^2 -> offsets 41 * 41 -> 42.
    let (task, dev, exe, inh, epoch) = (0x2001u32, 0xC0FFEE01u32, 0xE0E0u32, 0xABCDu32, 1u32);
    let (oa, ob, claimed) = (41u32, 41u32, 42u32);
    let out = claimed; // the receipt's result field carries the product exponent offset

    let d = digest256(task, dev, exe, 0x11, inh, out, epoch, receipt::RECEIPT_GENESIS);
    // Batch of two: our receipt (leaf0) and a sibling; root signed once.
    let sibling = [0x11111111u32; 8];
    let root = pair256(&d, &sibling);
    let batch_sig = sk.sign(&dbytes(&root));

    // A verifier's three checks for the honest receipt.
    let sig_ok = if vk.verify(&dbytes(&root), &batch_sig).is_ok() { 1u32 } else { 0 };
    let included = if pair256(&d, &sibling) == root { 1u32 } else { 0 };
    let compute_ok = if gfa::verify_gft_mul_offset(oa, ob, claimed, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX) { 1u32 } else { 0 };
    assert_eq!(verify::receipt_accepted(sig_ok, included, compute_ok), true, "honest receipt accepted");
    assert_eq!(verify::reject_reason(sig_ok, included, compute_ok), verify::OK);

    // Failure 1 -- WHO: a wrong signer.
    let wrong = SigningKey::from_bytes(&[9u8; 32]).verifying_key();
    let bad_sig = if wrong.verify(&dbytes(&root), &batch_sig).is_ok() { 1u32 } else { 0 };
    assert_eq!(verify::reject_reason(bad_sig, included, compute_ok), verify::BAD_SIG);

    // Failure 2 -- MEMBERSHIP: a receipt not under the signed root.
    let other = digest256(0x2099, dev, exe, 0x11, inh, out, epoch, receipt::RECEIPT_GENESIS);
    let not_incl = if pair256(&other, &sibling) == root { 1u32 } else { 0 };
    assert_eq!(verify::reject_reason(sig_ok, not_incl, compute_ok), verify::NOT_IN_BATCH);

    // Failure 3 -- CORRECTNESS: a receipt claiming a wrong product exponent (43 not 42).
    let bad_compute = if gfa::verify_gft_mul_offset(oa, ob, 43, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX) { 1u32 } else { 0 };
    assert_eq!(verify::reject_reason(sig_ok, included, bad_compute), verify::BAD_COMPUTE);

    println!("full compute-receipt verifier (WHO + MEMBERSHIP + CORRECTNESS):");
    println!("  honest receipt: sig_ok={} included={} compute_ok={} -> accepted={}", sig_ok, included, compute_ok, verify::receipt_accepted(sig_ok, included, compute_ok));
    println!("  wrong signer     -> reject_reason={} (BAD_SIG)", verify::reject_reason(bad_sig, included, compute_ok));
    println!("  not in batch     -> reject_reason={} (NOT_IN_BATCH)", verify::reject_reason(sig_ok, not_incl, compute_ok));
    println!("  claims phi^2=43  -> reject_reason={} (BAD_COMPUTE: a valid signature over a wrong result is still rejected)", verify::reject_reason(sig_ok, included, bad_compute));
    println!("OK: a receipt is accepted only if signed AND batched AND its GF-T compute recomputes");
}
