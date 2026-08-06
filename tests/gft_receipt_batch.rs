//! gft_receipt_batch -- scale verifiable compute to a BATCH: aggregate N GF-T dot-product
//! receipts into one SHA-256 Merkle root, so an A2A swarm settles a whole round of TaskResults
//! with a single signature + root instead of N signatures. Any single receipt is still auditable
//! (inclusion proof) and slashable (recompute), so aggregation costs nothing in security.
//!
//! This is the outward growth of gft_dot_verifiable: that proved one dot result is bound + correct;
//! this proves a BATCH of them commits to one root, any member is provable, a tampered member
//! changes the root, and a lying member is caught by recompute even inside the batch.

use ed25519_dalek::{Signer, SigningKey, Verifier};
use sha2::{Digest, Sha256};

// ---- GF-T16 dot oracle (integer; same fold as gft_dot_verifiable / on-silicon macc). ----
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
    let c = if prod >= (2 * MANT_ONE) * MANT_ONE {
        1
    } else {
        0
    };
    let mant = if c == 1 {
        (prod / (2 * MANT_ONE)) - MANT_ONE
    } else {
        (prod / MANT_ONE) - MANT_ONE
    };
    let sum = oa + ob + c;
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
fn dot(ops: &[(u16, u16)]) -> u16 {
    let mut acc = (0u64, 0u64);
    for (i, &(a, b)) in ops.iter().enumerate() {
        let p = mul(a, b);
        acc = if i == 0 { p } else { add(acc, p) };
    }
    (((acc.0 & 0x7F) << 9) | (acc.1 & 0x1FF)) as u16
}

// ---- one receipt + its leaf ----
#[derive(Clone)]
struct Receipt {
    executor: [u8; 32],
    operands: Vec<(u16, u16)>,
    result: u16,
}
fn h2(l: &[u8; 32], r: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(l);
    h.update(r);
    h.finalize().into()
}
fn leaf(rc: &Receipt) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update([0x00]); // domain-separate leaves from internal nodes
    h.update(rc.executor);
    for &(a, b) in &rc.operands {
        h.update(a.to_le_bytes());
        h.update(b.to_le_bytes());
    }
    h.update(rc.result.to_le_bytes());
    h.finalize().into()
}

// ---- minimal binary Merkle (duplicate last on odd rows) ----
fn merkle_root(leaves: &[[u8; 32]]) -> [u8; 32] {
    let mut row: Vec<[u8; 32]> = leaves.to_vec();
    while row.len() > 1 {
        let mut next = Vec::with_capacity(row.len().div_ceil(2));
        let mut i = 0;
        while i < row.len() {
            let l = row[i];
            let r = if i + 1 < row.len() {
                row[i + 1]
            } else {
                row[i]
            };
            next.push(h2(&l, &r));
            i += 2;
        }
        row = next;
    }
    row[0]
}
/// Sibling path for leaf `idx`.
fn merkle_proof(leaves: &[[u8; 32]], idx: usize) -> Vec<[u8; 32]> {
    let mut proof = Vec::new();
    let mut row: Vec<[u8; 32]> = leaves.to_vec();
    let mut i = idx;
    while row.len() > 1 {
        let sib = if i.is_multiple_of(2) {
            if i + 1 < row.len() {
                i + 1
            } else {
                i
            }
        } else {
            i - 1
        };
        proof.push(row[sib]);
        let mut next = Vec::new();
        let mut j = 0;
        while j < row.len() {
            let l = row[j];
            let r = if j + 1 < row.len() {
                row[j + 1]
            } else {
                row[j]
            };
            next.push(h2(&l, &r));
            j += 2;
        }
        row = next;
        i /= 2;
    }
    proof
}
fn merkle_verify(mut node: [u8; 32], mut idx: usize, proof: &[[u8; 32]], root: &[u8; 32]) -> bool {
    for sib in proof {
        node = if idx.is_multiple_of(2) {
            h2(&node, sib)
        } else {
            h2(sib, &node)
        };
        idx /= 2;
    }
    &node == root
}

fn sample_batch() -> Vec<Receipt> {
    let ex = [0xEE; 32];
    vec![
        Receipt {
            executor: ex,
            operands: vec![(0x5200, 0x5200); 4],
            result: dot(&[(0x5200, 0x5200); 4]),
        }, // 16
        Receipt {
            executor: ex,
            operands: vec![(0x5300, 0x5300), (0x5800, 0x5A00)],
            result: dot(&[(0x5300, 0x5300), (0x5800, 0x5A00)]),
        }, // 521
        Receipt {
            executor: ex,
            operands: vec![(0x5300, 0x5300), (0x5200, 0x5200), (0x5400, 0x5200)],
            result: dot(&[(0x5300, 0x5300), (0x5200, 0x5200), (0x5400, 0x5200)]),
        }, // 21
        Receipt {
            executor: ex,
            operands: vec![(0x6400, 0x6400)],
            result: dot(&[(0x6400, 0x6400)]),
        }, // 2^20
        Receipt {
            executor: ex,
            operands: vec![(0x5200, 0x5300)],
            result: dot(&[(0x5200, 0x5300)]),
        }, // 8
    ]
}

#[test]
fn every_receipt_proves_inclusion_in_the_batch_root() {
    let batch = sample_batch();
    let leaves: Vec<[u8; 32]> = batch.iter().map(leaf).collect();
    let root = merkle_root(&leaves);
    for (i, rc) in batch.iter().enumerate() {
        let proof = merkle_proof(&leaves, i);
        assert!(
            merkle_verify(leaf(rc), i, &proof, &root),
            "receipt {i} must prove inclusion"
        );
    }
}

#[test]
fn one_signature_settles_the_whole_batch() {
    let sk = SigningKey::from_bytes(&[0x44; 32]);
    let batch = sample_batch();
    let leaves: Vec<[u8; 32]> = batch.iter().map(leaf).collect();
    let root = merkle_root(&leaves);
    let sig = sk.sign(&root); // ONE signature for all N receipts
    assert!(
        sk.verifying_key().verify(&root, &sig).is_ok(),
        "the batch root signature must verify"
    );
}

#[test]
fn a_tampered_receipt_changes_the_root() {
    let batch = sample_batch();
    let root = merkle_root(&batch.iter().map(leaf).collect::<Vec<_>>());
    let mut tampered = batch.clone();
    tampered[2].result ^= 0x0001; // flip a bit in one receipt's result
    let root2 = merkle_root(&tampered.iter().map(leaf).collect::<Vec<_>>());
    assert_ne!(
        root, root2,
        "any tampered member must change the batch root"
    );
    // ...and its inclusion proof against the ORIGINAL root fails.
    let leaves2: Vec<[u8; 32]> = tampered.iter().map(leaf).collect();
    let proof = merkle_proof(&leaves2, 2);
    assert!(
        !merkle_verify(leaf(&tampered[2]), 2, &proof, &root),
        "tampered leaf must not prove against the old root"
    );
}

#[test]
fn a_lying_member_is_caught_by_recompute_inside_the_batch() {
    // A batch can be internally consistent (valid Merkle root) yet contain a receipt whose result
    // is arithmetically WRONG. The Merkle root proves what was claimed; the recompute proves truth.
    let mut batch = sample_batch();
    batch[1].result ^= 0x0001; // lie about dot #1
    let leaves: Vec<[u8; 32]> = batch.iter().map(leaf).collect();
    let root = merkle_root(&leaves);
    // The lying receipt still proves inclusion (the aggregator committed to the lie)...
    assert!(merkle_verify(
        leaf(&batch[1]),
        1,
        &merkle_proof(&leaves, 1),
        &root
    ));
    // ...but a challenger recomputes and slashes exactly that member.
    let slashed: Vec<usize> = batch
        .iter()
        .enumerate()
        .filter(|(_, rc)| dot(&rc.operands) != rc.result)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        slashed,
        vec![1],
        "recompute pinpoints the one lying member of the batch"
    );
}
