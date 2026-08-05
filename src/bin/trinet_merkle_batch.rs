//! trinet_merkle_batch -- prove 256-bit Merkle batching of compute receipts.
//!
//! A node that finishes many tasks should not sign/settle each receipt separately.
//! It commits N receipt digests under ONE 256-bit Merkle root (H(left||right) via
//! tri_compute_receipt.merkle_pair_pre + tri_sha256.sha256_compress), signs the root
//! ONCE (Ed25519), and each receipt is settled with an O(log N) inclusion proof.
//! Proven bit-exact against hashlib, with a working inclusion proof, tamper-evidence,
//! and a single batch signature -- matching Merkle-per-block DePIN ledgers.
#![allow(dead_code, unused)]

use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey, Signature};

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_compute_receipt.rs"]
mod receipt;
#[path = "../../gen/rust/tri_compute_settle.rs"]
mod settle;

/// H(left || right) for two 256-bit nodes: two-block SHA-256 over the 64-byte pair.
fn pair256(l: &[u32; 8], r: &[u32; 8]) -> [u32; 8] {
    let w = |i: u32| receipt::merkle_pair_pre(
        i, l[0], l[1], l[2], l[3], l[4], l[5], l[6], l[7],
        r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
    );
    let mut s1 = [0u32; 8];
    let mut k = 0u32;
    while k < 8 {
        s1[k as usize] = sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), k);
        k += 1;
    }
    let mut out = [0u32; 8];
    let mut j = 0u32;
    while j < 8 {
        out[j as usize] = sha::sha256_compress(s1[0], s1[1], s1[2], s1[3], s1[4], s1[5], s1[6], s1[7], w(16), w(17), w(18), w(19), w(20), w(21), w(22), w(23), w(24), w(25), w(26), w(27), w(28), w(29), w(30), w(31), j);
        j += 1;
    }
    out
}

/// Recompute a root from a leaf + its proof. Each step: (sibling, sibling_is_right).
fn verify_inclusion(leaf: &[u32; 8], proof: &[([u32; 8], bool)]) -> [u32; 8] {
    let mut cur = *leaf;
    for (sib, sib_on_right) in proof {
        cur = if *sib_on_right { pair256(&cur, sib) } else { pair256(sib, &cur) };
    }
    cur
}

fn root_bytes(r: &[u32; 8]) -> [u8; 32] {
    let mut b = [0u8; 32];
    for i in 0..8 { b[i * 4..i * 4 + 4].copy_from_slice(&r[i].to_be_bytes()); }
    b
}

fn main() {
    // Four receipt digests (leaves). leaf0 is a real digest from trinet_receipt_digest.
    let leaves: [[u32; 8]; 4] = [
        [0x14E71587, 0x4FD6B3AE, 0x82D49B28, 0xC326BAD9, 0x2C50BFE1, 0xB94E6D9B, 0x729665A3, 0x25B7B544],
        [0x11111111; 8],
        [0x22222222; 8],
        [0x33333333; 8],
    ];

    // Build the tree: n01 = H(l0,l1), n23 = H(l2,l3), root = H(n01,n23).
    let n01 = pair256(&leaves[0], &leaves[1]);
    let n23 = pair256(&leaves[2], &leaves[3]);
    let root = pair256(&n01, &n23);

    // (1) BIT-EXACT vs an independent hashlib Merkle tree.
    let root_kat: [u32; 8] = [
        0x5C88E07A, 0xF6C1A41C, 0xE2E40803, 0xAAE6BD24,
        0x268D153E, 0xDB26707E, 0xE1933161, 0x489C3155,
    ];
    assert_eq!(root, root_kat, "Merkle root must match hashlib exactly");

    // (2) Inclusion proof for leaf 0: siblings l1 (right) then n23 (right).
    let proof0 = [(leaves[1], true), (n23, true)];
    assert_eq!(verify_inclusion(&leaves[0], &proof0), root, "leaf 0 inclusion proof recomputes the root");
    // Inclusion proof for leaf 2: sibling l3 (right) then n01 (left).
    let proof2 = [(leaves[3], true), (n01, false)];
    assert_eq!(verify_inclusion(&leaves[2], &proof2), root, "leaf 2 inclusion proof recomputes the root");

    // (3) Tamper-evidence: change one bit of a leaf -> its proof no longer yields root.
    let mut bad = leaves[0];
    bad[7] ^= 1;
    assert_ne!(verify_inclusion(&bad, &proof0), root, "a tampered leaf fails inclusion");

    // (4) ONE batch signature over the root authorizes settling all four receipts,
    // each verified into the batch by its O(log N) inclusion proof.
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let vk = sk.verifying_key();
    let sig = sk.sign(&root_bytes(&root));
    let batch_ok = if vk.verify(&root_bytes(&root), &sig).is_ok() { 1u32 } else { 0u32 };
    assert_eq!(batch_ok, 1);

    let mut bal = 1000u32;
    let proofs = [
        (&leaves[0], &proof0[..]),
        (&leaves[2], &proof2[..]),
    ];
    let mut settled = 0u32;
    for (leaf, proof) in proofs {
        let included = if verify_inclusion(leaf, proof) == root { 1u32 } else { 0u32 };
        // settle only if the receipt is in the signed batch (included AND batch_ok).
        let ok = included & batch_ok;
        bal = settle::settle_signed(bal, 16, 1, 0x4100, 6, 9, 0, ok);
        settled += ok;
    }
    assert_eq!(settled, 2);
    assert_eq!(bal, 1032, "two included receipts settle under one batch signature");

    println!("256-bit Merkle batch of 4 receipts under one root/one signature:");
    println!("  root = {:08x}{:08x}..{:08x} (KAT-verified bit-exact vs hashlib)", root[0], root[1], root[7]);
    println!("  inclusion proofs: leaf0 (l1,n23), leaf2 (l3,n01) both recompute the root; tampered leaf fails");
    println!("  one Ed25519 signature over the root -> settled 2 included receipts, balance 1000 -> {}", bal);
    println!("OK: N receipts -> 1 root -> 1 signature + O(log N) proofs, via merkle_pair_pre + sha256_compress (multi-block)");
}
