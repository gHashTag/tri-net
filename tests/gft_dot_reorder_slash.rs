//! gft_dot_reorder_slash -- turn the reduction-order finding into a ring rule: a dot claim folded in
//! the WRONG order is slashed. gft_dot_reduction_order proved the tree and a left fold diverge; this
//! binds that into recompute-and-slash. An executor commits a receipt over its dot result; the
//! verifier recomputes with the CANONICAL tree (gft_dot4.v) and slashes any claim that does not match
//! -- so a reordered reduction is caught exactly like a wrong product, not silently tolerated.
//!
//! GF-T16 divergent lane products p=[(40,64),(45,0),(46,256),(40,64)]: tree=(47,9), left fold=(47,8).
//! The honest tree claim is paid; the reorder claim (47,8) is slashed; an arbitrary wrong claim is
//! slashed. The point: reduction order is part of what the receipt commits to.

// ---- GF-T16 add, transcribed from fpga/gft/gft_add.v (mant_one 512, sig 10). ----
const MANT_ONE: u64 = 512;
const OMAX: u64 = 80;
const SIG: u64 = 10;

fn add(a: (u64, u64), b: (u64, u64)) -> (u64, u64) {
    let (hi, lo) = if a.0 > b.0 || (a.0 == b.0 && a.1 >= b.1) {
        (a, b)
    } else {
        (b, a)
    };
    let d = hi.0 - lo.0;
    let sb = if d >= SIG { 0 } else { (MANT_ONE + lo.1) >> d };
    let sum = (MANT_ONE + hi.1) + sb;
    let carry = sum >= 2 * MANT_ONE;
    let off = if carry {
        let e = hi.0 + 1;
        if e >= OMAX {
            OMAX
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

/// Canonical 4-lane reduction: the silicon gft_dot4.v tree (p0+p1)+(p2+p3).
fn tree4(p: [(u64, u64); 4]) -> (u64, u64) {
    let s01 = add(p[0], p[1]);
    let s23 = add(p[2], p[3]);
    add(s01, s23)
}

/// A left fold -- a (well-meaning or malicious) executor that reduces in the wrong order.
fn seq4(p: [(u64, u64); 4]) -> (u64, u64) {
    add(add(add(p[0], p[1]), p[2]), p[3])
}

// ---- ring receipt + challenge ----
fn mix32(x: u32) -> u32 {
    let mut h = x ^ 0x9E37_79B9;
    h = h.wrapping_mul(0x85EB_CA77);
    h ^= h >> 15;
    h
}
fn receipt_leaf(dot: (u64, u64)) -> u32 {
    mix32((dot.0 as u32).rotate_left(9) ^ mix32(dot.1 as u32))
}

const RESOLVE_HONEST: u32 = 0;
const RESOLVE_SLASH: u32 = 1;

/// The verifier recomputes the dot with the CANONICAL tree and compares to the executor's committed
/// leaf. Anything not equal to the tree result -- a reorder, a wrong product, a tampered value -- slashes.
fn resolve(operands: [(u64, u64); 4], executor_leaf: u32) -> u32 {
    let canonical = receipt_leaf(tree4(operands));
    if canonical == executor_leaf {
        RESOLVE_HONEST
    } else {
        RESOLVE_SLASH
    }
}

const P: [(u64, u64); 4] = [(40, 64), (45, 0), (46, 256), (40, 64)];

#[test]
fn an_honest_tree_order_dot_is_paid() {
    let executor = receipt_leaf(tree4(P)); // (47,9)
    assert_eq!(
        resolve(P, executor),
        RESOLVE_HONEST,
        "the canonical tree claim is accepted"
    );
}

#[test]
fn a_reordered_reduction_is_slashed() {
    // The executor folded left-to-right and committed (47,8) -- a different value than the tree (47,9).
    let reordered = tree4(P);
    let wrong_order = seq4(P);
    assert_ne!(
        reordered, wrong_order,
        "the two orders genuinely differ (1 ULP)"
    );
    let executor = receipt_leaf(wrong_order); // commits (47,8)
    assert_eq!(
        resolve(P, executor),
        RESOLVE_SLASH,
        "a reordered reduction is slashed by the tree-order verifier"
    );
}

#[test]
fn an_arbitrary_wrong_dot_is_slashed() {
    let executor = receipt_leaf((47, 0)); // nonsense claim
    assert_eq!(
        resolve(P, executor),
        RESOLVE_SLASH,
        "a wrong dot is slashed"
    );
}
