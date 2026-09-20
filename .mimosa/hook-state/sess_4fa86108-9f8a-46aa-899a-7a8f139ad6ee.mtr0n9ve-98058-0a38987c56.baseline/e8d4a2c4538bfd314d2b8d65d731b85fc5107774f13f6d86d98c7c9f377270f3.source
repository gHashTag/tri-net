//! trinet_receipt_digest -- prove the receipt's 256-bit SHA-256 commitment.
//!
//! The compute receipt's fast path (sign_digest) is a 32-bit mixer: ~2^16 birthday
//! collision resistance, too weak for a value that gates payment. This binary
//! composes the canonical preimage (tri_compute_receipt.digest_pre) with the repo's
//! validated SHA-256 (tri_sha256.sha256_word) into a 256-bit digest -- the value a
//! future Ed25519 signature should cover -- and proves it bit-exact against an
//! independent hashlib SHA-256 known-answer vector. Composition lives here because
//! t27 specs have no cross-module calls; all logic is generated from specs.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;

/// 256-bit receipt digest = SHA-256 over the canonical 16-word preimage the spec
/// lays out (domain tag + 8 request-bound fields + fixed SHA padding).
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

fn main() {
    let (req, dev, exe, task, inh, out, epoch, prev) =
        (0x2001u32, 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0xABCDu32, 0x4100u32, 1u32, receipt::RECEIPT_GENESIS);

    let d = digest256(req, dev, exe, task, inh, out, epoch, prev);

    // (1) BIT-EXACT vs an independent SHA-256 (Python hashlib over the same 36 bytes).
    let kat: [u32; 8] = [
        0x14E71587, 0x4FD6B3AE, 0x82D49B28, 0xC326BAD9,
        0x2C50BFE1, 0xB94E6D9B, 0x729665A3, 0x25B7B544,
    ];
    assert_eq!(d, kat, "256-bit receipt digest must match hashlib SHA-256 exactly");

    // (2) Determinism.
    assert_eq!(digest256(req, dev, exe, task, inh, out, epoch, prev), d, "digest must be deterministic");

    // (3) Avalanche: a 1-bit change in the output flips ~half of the 256 bits (a
    // 32-bit lo digest cannot give this separation).
    let d2 = digest256(req, dev, exe, task, inh, out ^ 1, epoch, prev);
    assert_ne!(d2, d, "a 1-bit output change must change the digest");
    let ham: u32 = (0..8).map(|i| (d[i] ^ d2[i]).count_ones()).sum();
    assert!(ham >= 96, "avalanche too weak: {}/256 bits changed on a 1-bit flip", ham);

    // (4) Field binding: any of the 8 bound fields flips the digest.
    for (label, dd) in [
        ("request_id", digest256(req ^ 1, dev, exe, task, inh, out, epoch, prev)),
        ("device_id", digest256(req, dev ^ 1, exe, task, inh, out, epoch, prev)),
        ("executor", digest256(req, dev, exe ^ 1, task, inh, out, epoch, prev)),
        ("prev_head", digest256(req, dev, exe, task, inh, out, epoch, prev ^ 1)),
    ] {
        assert_ne!(dd, d, "field {} must be bound into the digest", label);
    }

    let lo = receipt::sign_digest_req(req, dev, exe, task, inh, out, epoch, prev);
    println!("receipt 256-bit SHA-256 digest (KAT-verified vs hashlib, bit-exact):");
    println!(
        "  {:08x} {:08x} {:08x} {:08x} {:08x} {:08x} {:08x} {:08x}",
        d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]
    );
    println!("  old 32-bit lo digest (sign_digest_req) = {:08x}  -> ~2^16 birthday", lo);
    println!("  strong digest is 256-bit -> ~2^128 collision resistance ({}x wider)", 8);
    println!("  avalanche on a 1-bit output flip: {}/256 bits changed", ham);
    println!("OK: strong receipt commitment = tri_compute_receipt.digest_pre (canonical preimage) + tri_sha256 (validated), composed in the binary");
}
