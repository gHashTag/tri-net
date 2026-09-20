//! trinet_settle_signed -- prove the authenticity gate: a receipt settles ONLY
//! when its 256-bit digest carries a valid executor Ed25519 signature.
//!
//! Ties three landed pieces together: the canonical 256-bit digest
//! (tri_compute_receipt.digest_pre + tri_sha256), a REAL Ed25519 signature over it
//! (ed25519-dalek, the Rust crate primitive -- signatures are not spec logic), and
//! the spec-defined payout policy (tri_compute_settle.settle_signed). The spec pays
//! only if sig_ok==1; this binary sets sig_ok by actually verifying the signature,
//! and shows a forged/tampered receipt earns nothing.
#![allow(dead_code, unused)]

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey, Signature};

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_compute_settle.rs"]
mod settle;

fn digest256(req: u32, dev: u32, exe: u32, task: u32, inh: u32, out: u32, epoch: u32, prev: u32) -> [u32; 8] {
    let w = |i: u32| receipt::digest_pre(i, req, dev, exe, task, inh, out, epoch, prev);
    let (w0, w1, w2, w3) = (w(0), w(1), w(2), w(3));
    let (w4, w5, w6, w7) = (w(4), w(5), w(6), w(7));
    let (w8, w9, w10, w11) = (w(8), w(9), w(10), w(11));
    let (w12, w13, w14, w15) = (w(12), w(13), w(14), w(15));
    let mut d = [0u32; 8];
    let mut j = 0u32;
    while j < 8 {
        d[j as usize] = sha::sha256_word(w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15, j);
        j += 1;
    }
    d
}

/// 8 big-endian u32 words -> 32 message bytes for Ed25519.
fn digest_bytes(d: &[u32; 8]) -> [u8; 32] {
    let mut b = [0u8; 32];
    for i in 0..8 {
        b[i * 4..i * 4 + 4].copy_from_slice(&d[i].to_be_bytes());
    }
    b
}

fn sig_ok(vk: &VerifyingKey, msg: &[u8; 32], sig: &Signature) -> u32 {
    if vk.verify(msg, sig).is_ok() { 1 } else { 0 }
}

fn main() {
    // Executor's fixed key (deterministic demo; production keys are per-node, W3b).
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let wrong_vk = SigningKey::from_bytes(&[9u8; 32]).verifying_key();

    let (req, dev, exe, task, inh, out, epoch, prev) =
        (0x2001u32, 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0xABCDu32, 0x4100u32, 1u32, receipt::RECEIPT_GENESIS);

    // Honest receipt: digest over the real fields, signed by the executor.
    let d = digest256(req, dev, exe, task, inh, out, epoch, prev);
    let msg = digest_bytes(&d);
    let sig = sk.sign(&msg);

    // (1) Valid signature -> sig_ok=1 -> a fresh finite receipt settles the reward.
    let ok = sig_ok(&vk, &msg, &sig);
    let paid = settle::settle_signed(1000, 16, 1, out, 6, 9, 0, ok);
    assert_eq!(ok, 1, "honest signature must verify");
    assert_eq!(paid, 1016, "valid signature + fresh + finite -> reward settles");

    // (2) FORGED result: attacker changes the output but cannot re-sign it. The
    // digest changes, the old signature no longer verifies -> sig_ok=0 -> no payout.
    let d_forge = digest256(req, dev, exe, task, inh, 0x9999, epoch, prev);
    let msg_forge = digest_bytes(&d_forge);
    let ok_forge = sig_ok(&vk, &msg_forge, &sig); // old sig over the forged digest
    let paid_forge = settle::settle_signed(1000, 16, 1, 0x9999, 6, 9, 0, ok_forge);
    assert_eq!(ok_forge, 0, "signature must NOT verify over a tampered digest");
    assert_eq!(paid_forge, 1000, "a forged receipt earns nothing");

    // (3) WRONG signer: a valid signature from another key does not settle for this
    // executor (only the bound executor's key is accepted).
    let ok_wrong = sig_ok(&wrong_vk, &msg, &sig);
    let paid_wrong = settle::settle_signed(1000, 16, 1, out, 6, 9, 0, ok_wrong);
    assert_eq!(ok_wrong, 0, "another key's verification must fail");
    assert_eq!(paid_wrong, 1000, "a receipt not signed by the executor earns nothing");

    println!("signature gate over the 256-bit receipt digest (real Ed25519):");
    println!("  honest  sig_ok={} -> settle 1000 -> {}", ok, paid);
    println!("  forged  sig_ok={} -> settle 1000 -> {} (output tampered, old sig invalid)", ok_forge, paid_forge);
    println!("  wrongkey sig_ok={} -> settle 1000 -> {} (valid sig, wrong signer)", ok_wrong, paid_wrong);
    println!("OK: payout is bound to a valid executor signature over the strong digest (policy in tri_compute_settle.settle_signed, verify in Rust)");
}
