//! trinet_ledger_head -- prove the 256-bit auditable ledger head.
//!
//! The old chain (tri_compute_receipt.chain_step_full) folds a 32-bit digest via a
//! 32-bit mixer: an auditor's head has ~2^16 resistance. This computes the head as a
//! real two-block SHA-256 over (prev_head_256 || leaf_256) -- both full width -- using
//! the multi-block extension of tri_sha256 (sha256_word for block 1 from the IV, then
//! sha256_compress from that state over the padding block). Proven bit-exact against
//! an independent hashlib SHA-256 known-answer vector, and tamper-evident: altering
//! any past leaf changes ~half the head bits. Composition is in this binary because
//! t27 specs have no cross-module calls; all round logic is generated from specs.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;

/// One two-block SHA-256 over the 64-byte message (prev_head 8 words || leaf 8 words).
/// This IS the chain step: new_head = SHA-256(prev_head || leaf).
fn chain_head(prev: &[u32; 8], leaf: &[u32; 8]) -> [u32; 8] {
    // Block 1 = prev || leaf (a full 512-bit block), compressed from the IV.
    let mut state1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 {
        state1[k as usize] = sha::sha256_word(
            prev[0], prev[1], prev[2], prev[3], prev[4], prev[5], prev[6], prev[7],
            leaf[0], leaf[1], leaf[2], leaf[3], leaf[4], leaf[5], leaf[6], leaf[7],
            k,
        );
        k += 1;
    }
    // Block 2 = the padding block for a 512-bit message, compressed from state1.
    let p = |i: u32| sha::sha256_pad2_word(i, 512);
    let mut head = [0u32; 8];
    let mut j = 0u32;
    while j < 8 {
        head[j as usize] = sha::sha256_compress(
            state1[0], state1[1], state1[2], state1[3], state1[4], state1[5], state1[6], state1[7],
            p(0), p(1), p(2), p(3), p(4), p(5), p(6), p(7),
            p(8), p(9), p(10), p(11), p(12), p(13), p(14), p(15),
            j,
        );
        j += 1;
    }
    head
}

fn hamming(a: &[u32; 8], b: &[u32; 8]) -> u32 {
    (0..8).map(|i| (a[i] ^ b[i]).count_ones()).sum()
}

fn main() {
    let prev: [u32; 8] = [0x54524352, 1, 2, 3, 4, 5, 6, 7]; // a 256-bit prior head
    let leaf: [u32; 8] = [
        0x14E71587, 0x4FD6B3AE, 0x82D49B28, 0xC326BAD9,
        0x2C50BFE1, 0xB94E6D9B, 0x729665A3, 0x25B7B544,
    ]; // the receipt's 256-bit digest (from trinet_receipt_digest)

    let head = chain_head(&prev, &leaf);

    // (1) BIT-EXACT vs an independent two-block hashlib SHA-256 over the 64 bytes.
    let kat: [u32; 8] = [
        0xF945F1F8, 0x1A2A2C5F, 0xB2E395AB, 0x0C55104B,
        0x9AB88D89, 0xBABC082B, 0x73B3ED66, 0x9113F1B2,
    ];
    assert_eq!(head, kat, "two-block ledger head must match hashlib SHA-256 exactly");

    // (2) Determinism.
    assert_eq!(chain_head(&prev, &leaf), head, "head must be deterministic");

    // (3) Tamper-evidence: change one bit of the LEAF (a past receipt) -> the head
    // moves by ~half its 256 bits (a 32-bit mixer head cannot give this).
    let mut leaf_t = leaf;
    leaf_t[7] ^= 1;
    let head_lt = chain_head(&prev, &leaf_t);
    assert_ne!(head_lt, head, "altering a leaf must change the head");
    let ham_leaf = hamming(&head, &head_lt);
    assert!(ham_leaf >= 96, "leaf-tamper avalanche too weak: {}/256", ham_leaf);

    // (4) History binding: change the PRIOR head -> the new head changes too, so a
    // spliced history cannot reproduce the same audited head.
    let mut prev_t = prev;
    prev_t[0] ^= 1;
    let head_pt = chain_head(&prev_t, &leaf);
    assert_ne!(head_pt, head, "altering the prior head must change the new head");
    let ham_prev = hamming(&head, &head_pt);

    println!("256-bit auditable ledger head = two-block SHA-256(prev_head || leaf):");
    println!(
        "  head = {:08x} {:08x} {:08x} {:08x} {:08x} {:08x} {:08x} {:08x}",
        head[0], head[1], head[2], head[3], head[4], head[5], head[6], head[7]
    );
    println!("  KAT-verified bit-exact vs hashlib (two-block, 64-byte message)");
    println!("  leaf-tamper avalanche:  {}/256 bits   history-tamper avalanche: {}/256 bits", ham_leaf, ham_prev);
    println!("OK: full 256-bit chaining (both prev head and leaf), via the tri_sha256 multi-block extension (sha256_compress)");
}
