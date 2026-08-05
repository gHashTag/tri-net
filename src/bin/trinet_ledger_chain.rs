//! trinet_ledger_chain -- prove the 256-bit SETTLED ledger head.
//!
//! Ties the whole ring together: each step takes a receipt, builds its 256-bit
//! digest (digest_pre + tri_sha256), verifies the executor's Ed25519 signature,
//! settles the balance (settle_signed), and advances a 256-bit ledger head that
//! commits {prev_head, receipt_digest, balance_after, epoch} via a two-block
//! SHA-256 (tri_compute_receipt.ledger_entry_pre + tri_sha256.sha256_compress).
//! So auditing the head verifies the settled BALANCE, not just that compute ran.
//! Proven bit-exact against hashlib, tamper-evident, and gated by a real signature.
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

/// 256-bit settled-ledger head = two-block SHA-256(prev_head || digest || balance || epoch || tag).
fn ledger_head256(prev: &[u32; 8], dg: &[u32; 8], balance: u32, epoch: u32) -> [u32; 8] {
    let w = |i: u32| receipt::ledger_entry_pre(
        i, prev[0], prev[1], prev[2], prev[3], prev[4], prev[5], prev[6], prev[7],
        dg[0], dg[1], dg[2], dg[3], dg[4], dg[5], dg[6], dg[7], balance, epoch,
    );
    // Block 1 (words 0..15) from the IV.
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 {
        s1[k as usize] = sha::sha256_word(
            w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7),
            w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k,
        );
        k += 1;
    }
    // Block 2 (words 16..31) from state1.
    let mut head = [0u32; 8];
    let mut j = 0u32;
    while j < 8 {
        head[j as usize] = sha::sha256_compress(
            s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7],
            w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23),
            w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j,
        );
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
fn hamming(a: &[u32; 8], b: &[u32; 8]) -> u32 { (0..8).map(|i| (a[i] ^ b[i]).count_ones()).sum() }

fn main() {
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();

    // Genesis head: seed word || zeros.
    let genesis: [u32; 8] = [receipt::LEDGER_GENESIS, 0, 0, 0, 0, 0, 0, 0];

    // --- Step 1: an honest, signed GF-T16 receipt settles and advances the head.
    let (req1, dev, exe, task, inh, out1) = (0x2001u32, 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0xABCDu32, 0x4100u32);
    let d1 = digest256(req1, dev, exe, task, inh, out1, 1, receipt::RECEIPT_GENESIS);
    let ok1 = sig_ok(&vk, &digest_bytes(&d1), &sk.sign(&digest_bytes(&d1)));
    let bal1 = settle::settle_signed(1000, 16, 1, out1, 6, 9, 0, ok1);
    let head1 = ledger_head256(&genesis, &d1, bal1, 1);
    assert_eq!(ok1, 1);
    assert_eq!(bal1, 1016, "step 1 settles +16");

    // (1) BIT-EXACT vs an independent two-block hashlib SHA-256.
    let head1_kat: [u32; 8] = [
        0x73C15740, 0xE149D4E2, 0x0764BAE3, 0x045A1C44,
        0x4CDB1E8F, 0xA8FCBFD7, 0xCDCAA72E, 0x3A8D3244,
    ];
    assert_eq!(head1, head1_kat, "ledger head must match hashlib two-block SHA-256");

    // (2) The head commits the BALANCE: settling a different balance moves the head.
    let head1_badbal = ledger_head256(&genesis, &d1, 9999, 1);
    assert_ne!(head1_badbal, head1, "a different settled balance must change the head");

    // --- Step 2: a second receipt chains onto head1.
    let (req2, out2) = (0x2002u32, 0x4200u32);
    let d2 = digest256(req2, dev, exe, task, inh, out2, 2, receipt::RECEIPT_GENESIS);
    let ok2 = sig_ok(&vk, &digest_bytes(&d2), &sk.sign(&digest_bytes(&d2)));
    let bal2 = settle::settle_signed(bal1, 16, 1, out2, 6, 9, 0, ok2);
    let head2 = ledger_head256(&head1, &d2, bal2, 2);
    assert_eq!(bal2, 1032, "step 2 settles +16 more");

    // (3) Tamper-evidence PROPAGATES: if step 1's balance is altered, head1' differs
    // and every later head (head2) computed from it diverges -- a rewritten history
    // cannot reproduce the audited tip.
    let head1_t = ledger_head256(&genesis, &d1, 1015, 1);
    let head2_from_tampered = ledger_head256(&head1_t, &d2, bal2, 2);
    assert_ne!(head2_from_tampered, head2, "altering step 1 diverges the step 2 head");
    let ham = hamming(&head2, &head2_from_tampered);

    // (4) Signature gate still holds at the ledger layer: a FORGED result earns
    // nothing and never advances the balance the head commits.
    let d_forge = digest256(req1, dev, exe, task, inh, 0x9999, 1, receipt::RECEIPT_GENESIS);
    let ok_forge = sig_ok(&vk, &digest_bytes(&d_forge), &sk.sign(&digest_bytes(&d1))); // old sig
    let bal_forge = settle::settle_signed(1000, 16, 1, 0x9999, 6, 9, 0, ok_forge);
    assert_eq!(ok_forge, 0);
    assert_eq!(bal_forge, 1000, "a forged receipt does not advance the ledger balance");

    println!("256-bit SETTLED ledger head = two-block SHA-256(prev || digest || balance || epoch):");
    println!("  step1 bal={} head1={:08x}{:08x}..{:08x} (KAT-verified bit-exact vs hashlib)", bal1, head1[0], head1[1], head1[7]);
    println!("  step2 bal={} head2={:08x}{:08x}..{:08x}", bal2, head2[0], head2[1], head2[7]);
    println!("  history-tamper propagation: step1 balance 1016->1015 diverges head2 by {}/256 bits", ham);
    println!("  forged receipt: sig_ok=0 -> balance stays 1000 (head never commits a forged settle)");
    println!("OK: signed 256-bit ledger -- head commits the balance, via ledger_entry_pre + sha256_compress (multi-block)");
}
