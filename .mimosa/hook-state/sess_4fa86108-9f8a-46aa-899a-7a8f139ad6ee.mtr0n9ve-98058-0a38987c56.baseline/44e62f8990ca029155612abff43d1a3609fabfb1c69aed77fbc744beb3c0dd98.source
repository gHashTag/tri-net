//! gft64_dot_reduction_order -- the reduction-order guard reaches the MONEY rung. gft_dot_reduction
//! _order pinned the canonical dot fold at GF-T16; the settle/escrow layer runs GF-T64 dots, where a
//! 1-ULP disagreement is a payout disagreement. GF-T64 add is non-associative too (the RTZ renorm
//! `sum>>1` truncates the low bit), so the fold order is just as load-bearing at 64 bits -- and it
//! was unguarded. The silicon MAC gft_dot4_64.v reduces with the balanced tree (m0+m1)+(m2+m3), so a
//! verifier recomputing a GF-T64 dot MUST fold that way or slash an honest executor.
//!
//! Witnessed on iverilog (gft_add64.v) for the lane-product vector
//!   p = [(9841,0), (9841,0), (9841, 2^63+3), (9841, 2^60+5)]
//! (four lanes at the same exponent, low bits set):
//!   TREE (p0+p1)+(p2+p3) = (9843, 2594073385365405698)   <- gft_dot4_64.v
//!   SEQ  ((p0+p1)+p2)+p3 = (9843, 2594073385365405697)   <- left fold; one ULP low

use num_bigint::BigUint;

fn pow2(k: u32) -> BigUint {
    BigUint::from(1u32) << k as usize
}

/// gft_add64, transcribed from fpga/gft/gft_add64.v: order by offset only (a is hi when equal),
/// align, add, renormalize one carry with a round-toward-zero `sum>>1`. mant_one 2^64, sig 65.
fn add64(a: &(u64, BigUint), b: &(u64, BigUint)) -> (u64, BigUint) {
    let m1 = pow2(64);
    let (omax, sig) = (19682u64, 65u64);
    let a_hi = a.0 >= b.0;
    let (hi_off, hi_m, lo_off, lo_m) = if a_hi {
        (a.0, &a.1, b.0, &b.1)
    } else {
        (b.0, &b.1, a.0, &a.1)
    };
    let d = hi_off - lo_off;
    let sb = if d >= sig {
        BigUint::from(0u32)
    } else {
        (&m1 + lo_m) >> (d as usize)
    };
    let sum = (&m1 + hi_m) + sb;
    let carry = sum >= &m1 * 2u32;
    let off = if carry {
        let e = hi_off + 1;
        if e >= omax {
            omax
        } else {
            e
        }
    } else {
        hi_off
    };
    let mant = if carry {
        (&sum >> 1u32) - &m1
    } else {
        &sum - &m1
    };
    (off, mant)
}

/// The silicon canonical GF-T64 reduction: the balanced tree of gft_dot4_64.v (a01, a23, atop).
/// Argument order matches the .v instantiation so the offset-only tie-break reproduces silicon.
fn tree4(p: &[(u64, BigUint); 4]) -> (u64, BigUint) {
    let s01 = add64(&p[0], &p[1]);
    let s23 = add64(&p[2], &p[3]);
    add64(&s01, &s23)
}

/// A left-fold reduction -- NOT what the silicon does; here to witness the divergence.
fn seq4(p: &[(u64, BigUint); 4]) -> (u64, BigUint) {
    let s0 = add64(&p[0], &p[1]);
    let s1 = add64(&s0, &p[2]);
    add64(&s1, &p[3])
}

fn divergent_vector() -> [(u64, BigUint); 4] {
    [
        (9841, BigUint::from(0u32)),
        (9841, BigUint::from(0u32)),
        (9841, pow2(63) + 3u32), // 2^63 + 3
        (9841, pow2(60) + 5u32), // 2^60 + 5
    ]
}

// iverilog witnesses on gft_add64.v (both < 2^62, so they fit u64).
fn tree_result() -> (u64, BigUint) {
    (9843, BigUint::from(2594073385365405698u64))
}
fn seq_result() -> (u64, BigUint) {
    (9843, BigUint::from(2594073385365405697u64))
}

#[test]
fn the_silicon_tree_order_is_the_canonical_gft64_dot() {
    assert_eq!(
        tree4(&divergent_vector()),
        tree_result(),
        "gft_dot4_64.v tree = (9843, ...698)"
    );
}

#[test]
fn a_reordered_gft64_reduction_diverges_by_one_ulp() {
    assert_eq!(
        seq4(&divergent_vector()),
        seq_result(),
        "left fold = (9843, ...697)"
    );
    assert_ne!(
        seq4(&divergent_vector()),
        tree4(&divergent_vector()),
        "GF-T64 reduction order is load-bearing: a reordered fold is a DIFFERENT value"
    );
}

#[test]
fn a_seq_verifier_would_falsely_slash_an_honest_gft64_payout() {
    // At the settle/escrow rung this 1-ULP gap is a payout disagreement: an executor running the
    // silicon tree returns ...698; a verifier folding sequentially compares against ...697 and rejects.
    let honest = tree4(&divergent_vector());
    let verifier_tree = tree4(&divergent_vector());
    let verifier_seq = seq4(&divergent_vector());
    assert_eq!(
        verifier_tree, honest,
        "tree-order verifier accepts the honest GF-T64 result"
    );
    assert_ne!(
        verifier_seq, honest,
        "seq-order verifier would falsely slash it"
    );
}

#[test]
fn four_ones_sum_to_four_at_gft64() {
    // Plain sanity: four 1.0 lanes = (9841,0) sum to 4.0 -> exponent 9843, mantissa 0.
    let ones = [
        (9841u64, BigUint::from(0u32)),
        (9841, BigUint::from(0u32)),
        (9841, BigUint::from(0u32)),
        (9841, BigUint::from(0u32)),
    ];
    assert_eq!(
        tree4(&ones),
        (9843, BigUint::from(0u32)),
        "4 x 1.0 = 4.0 -> (9843, 0)"
    );
}
