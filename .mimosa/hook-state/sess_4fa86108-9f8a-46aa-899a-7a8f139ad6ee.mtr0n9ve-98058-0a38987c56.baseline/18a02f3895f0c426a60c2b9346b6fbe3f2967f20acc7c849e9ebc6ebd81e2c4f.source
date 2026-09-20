//! trinet_node_identity -- prove the receipt.executor <-> signing-key binding.
//!
//! executor_id = low 32 bits of SHA-256(Ed25519 public key). A verifier recomputes
//! it from the key that signed the receipt and rejects any receipt whose executor
//! field does not match -- so a node cannot sign with its own key and claim to be a
//! different executor. The generated SHA-256 (tri_sha256 + tri_node_identity.pubkey_pre)
//! is cross-checked against the independent `sha2` crate.
#![allow(dead_code, unused)]

use ed25519_dalek::{SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

#[path = "../../gen/rust/tri_sha256.rs"]
mod sha;
#[path = "../../gen/rust/tri_node_identity.rs"]
mod ident;

/// executor id = low 32 bits of SHA-256(pubkey), computed from the generated spec.
fn executor_id(pubkey: &[u8; 32]) -> u32 {
    let mut k = [0u32; 8];
    for i in 0..8 { k[i] = u32::from_be_bytes([pubkey[i * 4], pubkey[i * 4 + 1], pubkey[i * 4 + 2], pubkey[i * 4 + 3]]); }
    let w = |i: u32| ident::pubkey_pre(i, k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7]);
    sha::sha256_word(w(0), w(1), w(2), w(3), w(4), w(5), w(6), w(7), w(8), w(9), w(10), w(11), w(12), w(13), w(14), w(15), 0)
}

fn main() {
    let sk = SigningKey::from_bytes(&[7u8; 32]);
    let pubkey = sk.verifying_key().to_bytes();

    let id = executor_id(&pubkey);

    // Cross-check the generated SHA-256 against the independent sha2 crate.
    let ref_digest = Sha256::digest(pubkey);
    let ref_id = u32::from_be_bytes([ref_digest[0], ref_digest[1], ref_digest[2], ref_digest[3]]);
    assert_eq!(id, ref_id, "generated SHA-256(pubkey) must match the sha2 crate");

    // Honest receipt: executor field == commitment to the signing key.
    let honest_executor = id;
    assert!(ident::identity_matches(honest_executor, id), "honest executor matches its key");
    assert!(ident::who_ok(1, honest_executor, id), "valid sig + matching identity -> who ok");

    // Forged receipt: signs with THIS key but claims a different executor (0xE0E0).
    let forged_executor = 0x0000E0E0u32;
    assert!(!ident::identity_matches(forged_executor, id), "claimed executor != key commitment");
    assert!(!ident::who_ok(1, forged_executor, id), "valid sig but wrong claimed identity -> who fails");

    println!("node identity binding (receipt.executor <-> Ed25519 signing key):");
    println!("  pubkey = {}..{}", hex4(&pubkey[0..4]), hex4(&pubkey[28..32]));
    println!("  executor_id = SHA-256(pubkey)[0..4] = {:08x} (KAT-matched vs sha2 crate)", id);
    println!("  honest receipt executor={:08x} -> matches -> who_ok=true", honest_executor);
    println!("  forged  receipt executor={:08x} (signed by this key) -> mismatch -> who_ok=false", forged_executor);
    println!("OK: a node cannot claim an executor id it does not hold the key for");
}

fn hex4(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}
