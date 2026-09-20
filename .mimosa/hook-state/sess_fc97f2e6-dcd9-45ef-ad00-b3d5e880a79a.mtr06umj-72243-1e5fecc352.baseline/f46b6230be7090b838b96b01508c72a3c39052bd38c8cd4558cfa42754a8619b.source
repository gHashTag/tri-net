//! gft_dot_verifiable -- verifiable compute at the WORKLOAD level: a GF-T16 dot product (the
//! matmul row that runs on silicon via gft_macc / gft_dot4) that is bound to its operand vector
//! AND recomputed-correct, or slashed. This grows the single-op unit (gft_verifiable_compute)
//! outward to the primitive an agent actually ships as a TaskResult.
//!
//! Model (maps onto A2A_MESH_BRIDGE): a TaskAssign carries the operand vector; the executor
//! returns a TaskResult = {input_hash = H(operands), result = dot(operands)} signed under its key.
//! A verifier holding the operands checks three things -- the Ed25519 signature binds
//! {executor, input_hash, result} (tamper-evidence); input_hash == H(operands) (bound to THESE
//! inputs); and dot(operands) == result (arithmetically correct, via recompute).
//! All three must hold; any single failure slashes the claim. The dot oracle is the same integer
//! gft_mul + gft_add fold as gft_dot_oracle (transcribed from tri_gft_arith / tri_gft_add).

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

// ---- GF-T16 dot-product oracle (integer). It folds lane products in the SILICON BALANCED-TREE
// order (gft_dot4.v: (p0+p1)+(p2+p3)), matching the on-silicon gft_macc / gft_dot4 at every lane
// count. GF-T add is non-associative (RTZ renorm), so a naive left fold would diverge from the tree
// at >=4 lanes and falsely slash an honest executor -- fixed here; see gft_dot_reduction_order for
// the divergence and the_tree_order_dot_matches_silicon_and_beats_a_left_fold below for the guard. ----
const BIAS: u64 = 40;
const OFFSET_MAX: u64 = 80;
const MANT_ONE: u64 = 512;
const SIG_BITS: u32 = 10;

fn mul(a: u16, b: u16) -> (u64, u64) {
    let ((oa, ma), (ob, mb)) = (
        ((a >> 9) as u64, (a & 0x1FF) as u64),
        ((b >> 9) as u64, (b & 0x1FF) as u64),
    );
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
    (off, mant)
}
fn add(a: (u64, u64), b: (u64, u64)) -> (u64, u64) {
    let (hi, lo) = if a.0 >= b.0 { (a, b) } else { (b, a) };
    let d = hi.0 - lo.0;
    let sb = if d >= SIG_BITS as u64 {
        0
    } else {
        (MANT_ONE + lo.1) >> d
    };
    let sum = (MANT_ONE + hi.1) + sb;
    let carry = sum >= 2 * MANT_ONE;
    let off = if carry {
        let e = hi.0 + 1;
        if e >= OFFSET_MAX {
            OFFSET_MAX
        } else {
            e
        }
    } else {
        hi.0
    };
    let mant = if carry {
        (sum >> 1) - MANT_ONE
    } else {
        sum - MANT_ONE
    };
    (off, mant)
}
fn dot(operands: &[(u16, u16)]) -> u16 {
    // Reduce the lane products in the SILICON BALANCED-TREE order (gft_dot4.v: (p0+p1)+(p2+p3)),
    // NOT a left fold. GF-T add is non-associative (RTZ renorm), so a left fold diverges from the
    // silicon tree at >=4 lanes and would falsely slash an honest executor (see tests/
    // gft_dot_reduction_order). Pairwise tree reduction: a level halves the vector, adding neighbors
    // and carrying an odd tail up. This is identical to the old left fold at 1..=3 lanes (one add,
    // or ((p0+p1)+p2)) and equals the silicon 3-adder tree at 4 lanes.
    let mut level: Vec<(u64, u64)> = operands.iter().map(|&(a, b)| mul(a, b)).collect();
    while level.len() > 1 {
        let mut next: Vec<(u64, u64)> = Vec::with_capacity(level.len().div_ceil(2));
        let mut i = 0;
        while i < level.len() {
            if i + 1 < level.len() {
                next.push(add(level[i], level[i + 1]));
            } else {
                next.push(level[i]); // odd tail carries up unchanged
            }
            i += 2;
        }
        level = next;
    }
    let acc = level.first().copied().unwrap_or((0, 0));
    (((acc.0 & 0x7F) << 9) | (acc.1 & 0x1FF)) as u16
}

fn hash_operands(operands: &[(u16, u16)]) -> [u8; 32] {
    let mut h = Sha256::new();
    for &(a, b) in operands {
        h.update(a.to_le_bytes());
        h.update(b.to_le_bytes());
    }
    h.finalize().into()
}

struct DotClaim {
    executor: [u8; 32],
    input_hash: [u8; 32],
    result: u16,
    sig: Signature,
}

fn issue(sk: &SigningKey, executor: [u8; 32], operands: &[(u16, u16)], result: u16) -> DotClaim {
    let input_hash = hash_operands(operands);
    let mut h = Sha256::new();
    h.update(executor);
    h.update(input_hash);
    h.update(result.to_le_bytes());
    let sig = sk.sign(&h.finalize());
    DotClaim {
        executor,
        input_hash,
        result,
        sig,
    }
}

fn sig_ok(pk: &VerifyingKey, c: &DotClaim) -> bool {
    let mut h = Sha256::new();
    h.update(c.executor);
    h.update(c.input_hash);
    h.update(c.result.to_le_bytes());
    pk.verify(&h.finalize(), &c.sig).is_ok()
}
/// The verifier holds the operands (from the TaskAssign) and checks all three layers.
fn accepted(pk: &VerifyingKey, c: &DotClaim, operands: &[(u16, u16)]) -> bool {
    sig_ok(pk, c)                                   // 1. tamper-evidence
        && c.input_hash == hash_operands(operands)  // 2. bound to THESE operands
        && dot(operands) == c.result // 3. arithmetically correct
}

fn sk() -> SigningKey {
    SigningKey::from_bytes(&[0x33; 32])
}

#[test]
fn honest_dot_claim_is_accepted() {
    let sk = sk();
    let ops = [(0x5300u16, 0x5300u16), (0x5200, 0x5200), (0x5400, 0x5200)]; // 9+4+8=21 -> 0x58A0
    let r = dot(&ops);
    assert_eq!(r, 0x58A0);
    let c = issue(&sk, [0xEE; 32], &ops, r);
    assert!(accepted(&sk.verifying_key(), &c, &ops));
}

#[test]
fn a_lying_executor_signs_a_wrong_dot_and_is_slashed() {
    let sk = sk();
    let ops = [(0x5300u16, 0x5300u16), (0x5200, 0x5200), (0x5400, 0x5200)];
    let c = issue(&sk, [0xEE; 32], &ops, 0x58A1); // signs a wrong sum (true is 0x58A0)
    assert!(
        sig_ok(&sk.verifying_key(), &c),
        "the signature over the wrong dot is valid..."
    );
    assert!(
        !accepted(&sk.verifying_key(), &c, &ops),
        "...but the recompute slashes it"
    );
}

#[test]
fn swapped_operands_break_the_binding() {
    let sk = sk();
    let ops = [(0x5300u16, 0x5300u16), (0x5200, 0x5200), (0x5400, 0x5200)];
    let c = issue(&sk, [0xEE; 32], &ops, dot(&ops));
    // The verifier is handed a DIFFERENT operand vector than the receipt committed to.
    let other_ops = [(0x5300u16, 0x5300u16), (0x5200, 0x5200), (0x5200, 0x5200)];
    assert!(sig_ok(&sk.verifying_key(), &c), "signature is intact");
    assert!(
        !accepted(&sk.verifying_key(), &c, &other_ops),
        "input_hash no longer matches the operands"
    );
}

#[test]
fn tampered_result_breaks_the_signature() {
    let sk = sk();
    let ops = [(0x5300u16, 0x5300u16), (0x5200, 0x5200)];
    let mut c = issue(&sk, [0xEE; 32], &ops, dot(&ops));
    c.result ^= 0x0001; // flip a bit of the result after signing
    assert!(
        !sig_ok(&sk.verifying_key(), &c),
        "post-sign result tamper breaks the receipt"
    );
    assert!(!accepted(&sk.verifying_key(), &c, &ops));
}

#[test]
fn oracle_agrees_with_silicon_vectors() {
    // The exact dot products verified bit-exact on the AX7203 (macc + dot4 tiles).
    assert_eq!(dot(&[(0x5200, 0x5200); 4]), 0x5800); // 4x(41,0)^2 = 16
    assert_eq!(dot(&[(0x5300, 0x5300), (0x5800, 0x5A00)]), 0x6209); // 9 + 512 = 521
    assert_eq!(
        dot(&[(0x5300, 0x5300), (0x5200, 0x5200), (0x5400, 0x5200)]),
        0x58A0
    ); // 21
}

// Regression for the sequential-fold bug (task_fe1cfda7): at >=4 lanes the oracle must fold in the
// silicon balanced-tree order, not a left fold. This searches GF16 operand quads for a case where a
// left fold DIVERGES from the tree, then asserts dot() computes the tree value (so an honest silicon
// executor is NOT falsely slashed) and NOT the left-fold value.
#[test]
fn the_tree_order_dot_matches_silicon_and_beats_a_left_fold() {
    // A left-fold reference over the SAME mul/add, for the comparison only.
    fn dot_leftfold(ops: &[(u16, u16)]) -> u16 {
        let mut acc = (0u64, 0u64);
        for (i, &(a, b)) in ops.iter().enumerate() {
            let p = mul(a, b);
            acc = if i == 0 { p } else { add(acc, p) };
        }
        (((acc.0 & 0x7F) << 9) | (acc.1 & 0x1FF)) as u16
    }
    // The silicon balanced tree for 4 lanes, computed directly.
    fn tree4(ops: &[(u16, u16); 4]) -> u16 {
        let p: Vec<(u64, u64)> = ops.iter().map(|&(a, b)| mul(a, b)).collect();
        let s01 = add(p[0], p[1]);
        let s23 = add(p[2], p[3]);
        let t = add(s01, s23);
        (((t.0 & 0x7F) << 9) | (t.1 & 0x1FF)) as u16
    }
    // Search operand quads (varying offset+mant) for a left-fold vs tree divergence.
    let vals: [u16; 6] = [0x5000, 0x5240, 0x5680, 0x5A80, 0x4E20, 0x52C0];
    let mut found = 0;
    for &a in &vals {
        for &b in &vals {
            for &c in &vals {
                for &d in &vals {
                    let quad = [(a, a), (b, b), (c, c), (d, d)];
                    let tree = tree4(&quad);
                    let left = dot_leftfold(&quad);
                    if tree != left {
                        // dot() must match the silicon tree, never the left fold.
                        assert_eq!(dot(&quad), tree, "dot must fold in the silicon tree order");
                        assert_ne!(dot(&quad), left, "dot must NOT match a left fold (the bug)");
                        found += 1;
                    } else {
                        // where they agree, dot() equals both (2/3-lane and non-divergent 4-lane).
                        assert_eq!(dot(&quad), tree);
                    }
                }
            }
        }
    }
    assert!(
        found > 0,
        "the search must exhibit at least one left-fold vs tree divergence"
    );
}
