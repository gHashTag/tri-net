//! gft_verifiable_compute -- the end-to-end unit: a GF-T compute result that is BOTH bound to
//! its input AND arithmetically correct, or it is rejected. This composes the two proven halves
//! (gft_receipt_binding + gft_compute_challenge) into one flow and shows they catch two DISTINCT
//! fraud modes that neither alone covers:
//!
//!   * tamper the output AFTER signing        -> the Ed25519 receipt no longer verifies (binding).
//!   * sign a WRONG output honestly (a lying   -> the signature is valid, but a challenger's
//!     executor)                                  gft_mul recompute disagrees (correctness/slash).
//!
//! Verifiable compute needs BOTH: a signature proves who/what, a recompute proves the value.
//! Primitives are the ones the spec pins (sha2 + ed25519-dalek); the multiply is the integer
//! oracle from tri_gft_arith (as in gft_compute_challenge). GF-T16 packed = (offset<<9)|mant.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

// ---- GF-T16 multiply oracle (integer; transcribed from tri_gft_arith). ----
const BIAS: u64 = 40;
const OFFSET_MAX: u64 = 80;
const MANT_ONE: u64 = 512;

fn gft_mul(a: u16, b: u16) -> u16 {
    let (oa, ma) = ((a >> 9) as u64, (a & 0x1FF) as u64);
    let (ob, mb) = ((b >> 9) as u64, (b & 0x1FF) as u64);
    let prod = (MANT_ONE + ma) * (MANT_ONE + mb);
    let carry = if prod >= (2 * MANT_ONE) * MANT_ONE {
        1
    } else {
        0
    };
    let mant = if carry == 1 {
        (prod / (2 * MANT_ONE)) - MANT_ONE
    } else {
        (prod / MANT_ONE) - MANT_ONE
    };
    let sum = oa + ob + carry;
    let off = if sum < BIAS {
        0
    } else {
        let r = sum - BIAS;
        if r >= OFFSET_MAX {
            OFFSET_MAX
        } else {
            r
        }
    };
    (((off & 0x7F) << 9) | (mant & 0x1FF)) as u16
}

/// A signed claim: executor E asserts `output = a * b` (GF-T16), over its own key.
struct ComputeClaim {
    executor: [u8; 32], // SHA-256(pubkey)
    a: u16,
    b: u16,
    output: u16,
    sig: Signature,
}

fn digest(executor: &[u8; 32], a: u16, b: u16, output: u16) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(executor);
    h.update(a.to_le_bytes());
    h.update(b.to_le_bytes());
    h.update(output.to_le_bytes());
    h.finalize().into()
}

fn issue(sk: &SigningKey, executor: [u8; 32], a: u16, b: u16, output: u16) -> ComputeClaim {
    let sig = sk.sign(&digest(&executor, a, b, output));
    ComputeClaim {
        executor,
        a,
        b,
        output,
        sig,
    }
}

/// Layer 1 -- binding: the receipt genuinely commits to (executor, a, b, output).
fn binding_ok(pk: &VerifyingKey, c: &ComputeClaim) -> bool {
    pk.verify(&digest(&c.executor, c.a, c.b, c.output), &c.sig)
        .is_ok()
}

/// Layer 2 -- correctness: a challenger recomputes and compares.
fn correct_ok(c: &ComputeClaim) -> bool {
    gft_mul(c.a, c.b) == c.output
}

/// A claim is accepted only if BOTH hold; otherwise the executor is slashed.
fn accepted(pk: &VerifyingKey, c: &ComputeClaim) -> bool {
    binding_ok(pk, c) && correct_ok(c)
}

#[test]
fn honest_claim_is_accepted() {
    let sk = SigningKey::from_bytes(&[0x11; 32]);
    let pk = sk.verifying_key();
    // (41,256)^2 -> (43,64): 0x5300 * 0x5300 -> 0x5640
    let out = gft_mul(0x5300, 0x5300);
    assert_eq!(out, 0x5640);
    let c = issue(&sk, [0xEE; 32], 0x5300, 0x5300, out);
    assert!(
        accepted(&pk, &c),
        "an honest, correct, signed claim must be accepted"
    );
}

#[test]
fn tampered_output_fails_binding() {
    let sk = SigningKey::from_bytes(&[0x11; 32]);
    let pk = sk.verifying_key();
    let mut c = issue(&sk, [0xEE; 32], 0x5300, 0x5300, gft_mul(0x5300, 0x5300));
    c.output ^= 0x0001; // flip a bit AFTER signing
    assert!(
        !binding_ok(&pk, &c),
        "post-sign tamper must break the receipt"
    );
    assert!(!accepted(&pk, &c));
}

#[test]
fn a_lying_executor_signs_a_wrong_result_and_is_slashed() {
    let sk = SigningKey::from_bytes(&[0x11; 32]);
    let pk = sk.verifying_key();
    // Malicious executor honestly SIGNS a wrong product (0x5640 is right; claim 0x5641).
    let c = issue(&sk, [0xEE; 32], 0x5300, 0x5300, 0x5641);
    assert!(
        binding_ok(&pk, &c),
        "the signature over the wrong value is itself valid..."
    );
    assert!(!correct_ok(&c), "...but the recompute exposes the lie");
    assert!(
        !accepted(&pk, &c),
        "so the claim is slashed -- signature alone is not enough"
    );
}

#[test]
fn two_fraud_modes_need_two_layers() {
    // Each layer catches a fraud the other misses, so only the conjunction is safe.
    let sk = SigningKey::from_bytes(&[0x11; 32]);
    let pk = sk.verifying_key();

    // (A) A lying executor signs a WRONG output. correct_ok is the only layer that catches it;
    //     binding_ok is satisfied (the signature over the wrong value is genuine).
    let lie = issue(&sk, [0xEE; 32], 0x5200, 0x5200, 0x5401); // correct is 0x5400
    assert!(binding_ok(&pk, &lie), "binding alone would accept the lie");
    assert!(!correct_ok(&lie), "only correctness catches it");

    // (B) A third party REATTRIBUTES a correct result to a different executor. binding_ok is the
    //     only layer that catches it; correct_ok ignores who ran it, so it stays true.
    let mut reattributed = issue(&sk, [0xEE; 32], 0x5200, 0x5200, gft_mul(0x5200, 0x5200));
    reattributed.executor[0] ^= 0x01;
    assert!(
        correct_ok(&reattributed),
        "correctness alone would accept the reattribution"
    );
    assert!(!binding_ok(&pk, &reattributed), "only binding catches it");

    // Neither claim is accepted -- the conjunction is what makes compute verifiable.
    assert!(!accepted(&pk, &lie) && !accepted(&pk, &reattributed));
}
