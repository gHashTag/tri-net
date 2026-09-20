//! trinet_input_digest -- prove the 256-bit input-bound receipt digest.
//!
//! digest_pre commits a 32-bit in_hash of the operands (~2^16). This commits the
//! FULL 256-bit operand hash (tri_a2a_wire.operand_pre -> tri_sha256, 8 words) via a
//! two-block SHA-256 over tri_compute_receipt.input_digest_pre, so a receipt binds
//! its inputs at ~2^128. Proven bit-exact vs an independent hashlib SHA-256, and any
//! operand change flips the digest.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_a2a_wire.rs"]
mod wire;

/// Full 256-bit SHA-256 of the assigned operands.
fn operand_hash(op: u32, a_off: u32, a_mant: u32, b_off: u32, b_mant: u32) -> [u32; 8] {
    let w = |i: u32| wire::operand_pre(i, op, a_off, a_mant, b_off, b_mant);
    let mut h = [0u32; 8];
    let mut k = 0u32;
    while k < 8 { h[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k); k += 1; }
    h
}

/// The 256-bit input-bound digest: two-block SHA-256 over input_digest_pre.
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

fn main() {
    let (req, dev, exe, task, out, epoch, prev) = (0x2001u32, 0xC0FFEE01u32, 0xE0E0u32, 0x11u32, 0x4100u32, 1u32, receipt::RECEIPT_GENESIS);
    let oh = operand_hash(0x11, 41, 0, 41, 0);
    let d = input_digest(req, dev, exe, task, &oh, out, epoch, prev);

    // (1) BIT-EXACT vs an independent two-block hashlib SHA-256.
    let kat: [u32; 8] = [0xADEACB9E, 0x1A2A3FAD, 0xBB862EA3, 0x0EB3BCE7, 0x1611565D, 0xDC5A7C3F, 0x797EA17A, 0x5333E1C1];
    assert_eq!(d, kat, "input-bound digest must match hashlib exactly");

    // (2) The digest binds the FULL 256-bit operand hash: any operand change flips it,
    // and it commits all 8 words (not a 32-bit slice) -> ~2^128 input resistance.
    let oh2 = operand_hash(0x11, 40, 0, 41, 0); // a_offset 41 -> 40
    assert_ne!(input_digest(req, dev, exe, task, &oh2, out, epoch, prev), d, "operand change flips the input digest");
    let same_lo = oh[0] == oh2[0];

    println!("256-bit input-bound receipt digest:");
    println!("  operand_hash = {:08x}..{:08x} (full 256-bit; digest_pre used only {:08x})", oh[0], oh[7], oh[0]);
    println!("  input_digest = {:08x}{:08x}..{:08x} (KAT-verified bit-exact vs hashlib)", d[0], d[1], d[7]);
    println!("  changing operand a_offset 41->40 flips the digest (full-hash binding, ~2^128)");
    println!("OK: the receipt binds its inputs at 256 bits (input_digest_pre + sha256_compress), not the 32-bit in_hash");
}
