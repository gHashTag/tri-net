//! gft_ledger_settlement -- the optimistic SETTLEMENT layer over batched GF-T compute receipts.
//! Batch roots (gft_receipt_batch) are appended to a hash-chained ledger and finalize only after a
//! challenge WINDOW elapses unchallenged; within the window, anyone who recomputes a wrong member
//! rejects the batch before it settles. This closes the ring outward: op -> dot -> batch -> ledger.
//!
//! Not a re-implementation of the spec ring (tri_compute_settle / _optimistic / tri_ledger) but a
//! CI-runnable guardrail for the property those specs encode: honest batches finalize into a
//! tamper-evident chained head; a batch containing an arithmetically wrong dot cannot finalize.

use sha2::{Digest, Sha256};

// ---- GF-T16 dot oracle (integer; same fold as the on-silicon macc / gft_dot_verifiable). ----
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

#[derive(Clone)]
struct Receipt {
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
    h.update([0x00]);
    for &(a, b) in &rc.operands {
        h.update(a.to_le_bytes());
        h.update(b.to_le_bytes());
    }
    h.update(rc.result.to_le_bytes());
    h.finalize().into()
}
fn merkle_root(leaves: &[[u8; 32]]) -> [u8; 32] {
    let mut row: Vec<[u8; 32]> = leaves.to_vec();
    if row.is_empty() {
        return [0; 32];
    }
    while row.len() > 1 {
        let mut next = Vec::with_capacity(row.len().div_ceil(2));
        let mut i = 0;
        while i < row.len() {
            let r = if i + 1 < row.len() {
                row[i + 1]
            } else {
                row[i]
            };
            next.push(h2(&row[i], &r));
            i += 2;
        }
        row = next;
    }
    row[0]
}

/// A batch is VALID iff every member's claimed result equals the honest recompute.
fn batch_valid(batch: &[Receipt]) -> bool {
    batch.iter().all(|rc| dot(&rc.operands) == rc.result)
}

// ---- Optimistic ledger: chained head, finality after WINDOW epochs unchallenged. ----
const WINDOW: u64 = 3;

struct Entry {
    epoch: u64,
    head: [u8; 32], // H(prev_head || epoch || root) -- commits the batch root into the chain
}
struct Ledger {
    entries: Vec<Entry>,
}
impl Ledger {
    fn new() -> Self {
        Ledger { entries: vec![] }
    }
    fn head(&self) -> [u8; 32] {
        self.entries.last().map(|e| e.head).unwrap_or([0; 32])
    }
    /// Submit a batch at `epoch`. Rejected immediately if a challenger can recompute a wrong member.
    fn submit(&mut self, epoch: u64, batch: &[Receipt]) -> Result<[u8; 32], &'static str> {
        if !batch_valid(batch) {
            return Err("challenged: a member's dot is wrong");
        }
        let root = merkle_root(&batch.iter().map(leaf).collect::<Vec<_>>());
        let mut h = Sha256::new();
        h.update(self.head());
        h.update(epoch.to_le_bytes());
        h.update(root);
        let head = h.finalize().into();
        self.entries.push(Entry { epoch, head });
        Ok(head)
    }
    /// An entry is final once WINDOW epochs have passed since it was submitted.
    fn is_final(&self, idx: usize, now: u64) -> bool {
        idx < self.entries.len() && now >= self.entries[idx].epoch + WINDOW
    }
}

fn honest(ops: Vec<(u16, u16)>) -> Receipt {
    let r = dot(&ops);
    Receipt {
        operands: ops,
        result: r,
    }
}

#[test]
fn honest_batches_chain_and_finalize() {
    let mut l = Ledger::new();
    l.submit(
        10,
        &[
            honest(vec![(0x5200, 0x5200); 4]),
            honest(vec![(0x6400, 0x6400)]),
        ],
    )
    .unwrap();
    l.submit(11, &[honest(vec![(0x5300, 0x5300), (0x5800, 0x5A00)])])
        .unwrap();
    assert_eq!(l.entries.len(), 2);
    // entry 0 (epoch 10) is final at now=13 (10 + WINDOW); entry 1 (epoch 11) is not yet.
    assert!(l.is_final(0, 13));
    assert!(!l.is_final(1, 13));
    assert!(l.is_final(1, 14));
}

#[test]
fn a_batch_with_a_lying_member_cannot_settle() {
    let mut l = Ledger::new();
    // one member claims a wrong dot (0x5801 instead of 0x5800 for 4x(41,0)^2 = 16)
    let liar = Receipt {
        operands: vec![(0x5200, 0x5200); 4],
        result: 0x5801,
    };
    let res = l.submit(10, &[honest(vec![(0x6400, 0x6400)]), liar]);
    assert_eq!(res, Err("challenged: a member's dot is wrong"));
    assert_eq!(
        l.entries.len(),
        0,
        "a challenged batch never enters the ledger, so never finalizes"
    );
}

#[test]
fn the_finalized_head_is_a_tamper_evident_chain() {
    let mut a = Ledger::new();
    a.submit(10, &[honest(vec![(0x5200, 0x5200); 4])]).unwrap();
    a.submit(11, &[honest(vec![(0x6400, 0x6400)])]).unwrap();

    // A ledger that settled a DIFFERENT batch at epoch 11 has a different head -- the chain binds order+content.
    let mut b = Ledger::new();
    b.submit(10, &[honest(vec![(0x5200, 0x5200); 4])]).unwrap();
    b.submit(11, &[honest(vec![(0x5200, 0x5300)])]).unwrap(); // different batch

    assert_ne!(
        a.head(),
        b.head(),
        "the chained head commits to the whole settled history"
    );
}
