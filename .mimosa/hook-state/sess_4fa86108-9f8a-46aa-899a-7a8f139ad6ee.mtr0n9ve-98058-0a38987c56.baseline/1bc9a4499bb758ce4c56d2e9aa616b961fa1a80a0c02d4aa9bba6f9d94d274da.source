//! gft_receipt_binding -- executable proof of the compute-receipt tamper-binding property.
//!
//! `specs/tri_compute_receipt.t27` seals an agent's WORK: a leaf commits
//! {executor, task, input_hash, output, epoch} into a SHA-256 canonical preimage, and an Ed25519
//! signature over that digest gates payment. The spec pins BOTH primitives to real Rust crates
//! ("the Ed25519 signature stays a Rust crate primitive ... the real 256-bit digest is
//! tri_sha256.sha256_word"). This test exercises that exact binding with the SAME primitives the
//! crate ships (`sha2` + `ed25519-dalek`) and proves the security property the ring depends on:
//!
//!   changing ANY committed field -- the output, the input it was computed over, the executor, or
//!   the epoch -- changes the digest, so the receipt signature no longer verifies. A forged result
//!   cannot ride a receipt minted for a different result.
//!
//! Scope, honestly: this validates the binding PROPERTY against the primitives, not the generated
//! `gen/rust/tri_compute_receipt.rs` (which needs t27c + is not committed / not CI-built). It is
//! the CI-runnable guardrail for "a tampered compute result is rejected", the heart of verifiable
//! compute. Run: `cargo test --test gft_receipt_binding`.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

/// The committed content of one compute receipt leaf (mirrors tri_compute_receipt's leaf).
#[derive(Clone)]
struct ComputeLeaf {
    executor: [u8; 32],   // SHA-256(pubkey) identity of who ran it
    task: [u8; 32],       // task id
    input_hash: [u8; 32], // 256-bit commitment to the operands
    output: Vec<u8>,      // the claimed compute result (e.g. a GF-T encoded value)
    epoch: u64,
}

/// Canonical single-preimage SHA-256 digest over the committed fields (length-prefixed output so
/// no two distinct leaves collide by concatenation ambiguity).
fn digest(leaf: &ComputeLeaf) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(leaf.executor);
    h.update(leaf.task);
    h.update(leaf.input_hash);
    h.update((leaf.output.len() as u64).to_le_bytes());
    h.update(&leaf.output);
    h.update(leaf.epoch.to_le_bytes());
    h.finalize().into()
}

/// A receipt = Ed25519 signature over the leaf digest.
fn issue(sk: &SigningKey, leaf: &ComputeLeaf) -> Signature {
    sk.sign(&digest(leaf))
}

/// Verify a receipt binds this exact leaf under this executor's key.
fn verify(pk: &VerifyingKey, leaf: &ComputeLeaf, sig: &Signature) -> bool {
    pk.verify(&digest(leaf), sig).is_ok()
}

fn sample_leaf() -> ComputeLeaf {
    ComputeLeaf {
        executor: [0x11; 32],
        task: [0x22; 32],
        input_hash: [0x33; 32],
        // pretend GF-T16 encoded result (offset<<9 | mant) for (41,256)^2 -> (43,64) etc.
        output: vec![0x2B, 0x40, 0x00, 0x00],
        epoch: 7,
    }
}

#[test]
fn honest_receipt_verifies() {
    let sk = SigningKey::from_bytes(&[0xA5; 32]);
    let pk = sk.verifying_key();
    let leaf = sample_leaf();
    let sig = issue(&sk, &leaf);
    assert!(
        verify(&pk, &leaf, &sig),
        "an untampered receipt must verify"
    );
}

#[test]
fn tampered_output_is_rejected() {
    let sk = SigningKey::from_bytes(&[0xA5; 32]);
    let pk = sk.verifying_key();
    let leaf = sample_leaf();
    let sig = issue(&sk, &leaf);

    // Flip one bit of the claimed result -- the forgery a slasher must catch.
    let mut forged = leaf.clone();
    forged.output[0] ^= 0x01;
    assert!(
        !verify(&pk, &forged, &sig),
        "a receipt must NOT verify a different output -- forged result would ride a real receipt"
    );
}

#[test]
fn tampered_input_is_rejected() {
    let sk = SigningKey::from_bytes(&[0xA5; 32]);
    let pk = sk.verifying_key();
    let leaf = sample_leaf();
    let sig = issue(&sk, &leaf);

    // Same output, but claim it was computed over different operands.
    let mut forged = leaf.clone();
    forged.input_hash[0] ^= 0x01;
    assert!(
        !verify(&pk, &forged, &sig),
        "the result must be bound to the input it was computed over"
    );
}

#[test]
fn tampered_executor_or_epoch_is_rejected() {
    let sk = SigningKey::from_bytes(&[0xA5; 32]);
    let pk = sk.verifying_key();
    let leaf = sample_leaf();
    let sig = issue(&sk, &leaf);

    let mut wrong_exec = leaf.clone();
    wrong_exec.executor[0] ^= 0x01;
    assert!(
        !verify(&pk, &wrong_exec, &sig),
        "cannot reattribute work to another executor"
    );

    let mut wrong_epoch = leaf.clone();
    wrong_epoch.epoch += 1;
    assert!(
        !verify(&pk, &wrong_epoch, &sig),
        "cannot replay a receipt into a different epoch"
    );
}

#[test]
fn wrong_key_and_swapped_signature_are_rejected() {
    let sk = SigningKey::from_bytes(&[0xA5; 32]);
    let pk = sk.verifying_key();
    let leaf = sample_leaf();
    let sig = issue(&sk, &leaf);

    // A different executor's key must not validate this receipt.
    let other = SigningKey::from_bytes(&[0x5A; 32]).verifying_key();
    assert!(
        !verify(&other, &leaf, &sig),
        "receipt is bound to the issuing key"
    );

    // A signature minted for a different leaf must not validate this one.
    let mut other_leaf = leaf.clone();
    other_leaf.task[0] ^= 0x01;
    let other_sig = issue(&sk, &other_leaf);
    assert!(
        !verify(&pk, &leaf, &other_sig),
        "a receipt from another task must not transfer"
    );
}
