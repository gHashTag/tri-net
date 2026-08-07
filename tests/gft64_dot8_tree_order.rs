//! gft64_dot8_tree_order -- the reduction-order guard scales to an 8-lane GF-T64 tile. Real matmul
//! tiles are wider than 4 lanes; the systolic array composes gft_dot4_64 tiles, so an 8-lane dot is
//! two dot4 subtrees summed: ((p0+p1)+(p2+p3)) + ((p4+p5)+(p6+p7)). With more reduction levels the
//! non-associativity of GF-T64 add accumulates, so the gap between the canonical tile tree and a
//! naive flat fold GROWS -- 2 ULP here vs 1 ULP at 4 lanes (gft64_dot_reduction_order).
//!
//! Witnessed on iverilog (gft_add64.v) for eight lanes = two copies of the 4-lane divergent vector
//! p4 = [(9841,0),(9841,0),(9841,2^63+3),(9841,2^60+5)]:
//!   TREE8 two dot4 subtrees + top add = (9844, 2594073385365405698)   <- the tile composition
//!   FLAT8 left fold over all 8 lanes  = (9844, 2594073385365405696)   <- two ULP low

use num_bigint::BigUint;

fn pow2(k: u32) -> BigUint {
    BigUint::from(1u32) << k as usize
}

/// gft_add64, transcribed from fpga/gft/gft_add64.v (offset-only ordering; RTZ `sum>>1` renorm).
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

/// 4-lane balanced tree (gft_dot4_64.v): (p0+p1)+(p2+p3).
fn tree4(p: &[(u64, BigUint)]) -> (u64, BigUint) {
    let s01 = add64(&p[0], &p[1]);
    let s23 = add64(&p[2], &p[3]);
    add64(&s01, &s23)
}

/// 8-lane tile tree: two dot4 subtrees summed -- how a systolic array of gft_dot4_64 tiles reduces.
fn tree8(p: &[(u64, BigUint); 8]) -> (u64, BigUint) {
    let left = tree4(&p[0..4]);
    let right = tree4(&p[4..8]);
    add64(&left, &right)
}

/// A flat left fold over all 8 lanes -- NOT the tile composition; here to witness the wider gap.
fn flat8(p: &[(u64, BigUint); 8]) -> (u64, BigUint) {
    let mut acc = add64(&p[0], &p[1]);
    for lane in p.iter().skip(2) {
        acc = add64(&acc, lane);
    }
    acc
}

fn eight_lanes() -> [(u64, BigUint); 8] {
    let l = || {
        [
            (9841u64, BigUint::from(0u32)),
            (9841, BigUint::from(0u32)),
            (9841, pow2(63) + 3u32),
            (9841, pow2(60) + 5u32),
        ]
    };
    let [a, b, c, d] = l();
    let [e, f, g, h] = l();
    [a, b, c, d, e, f, g, h]
}

#[test]
fn the_eight_lane_tile_tree_matches_the_silicon_composition() {
    // Two gft_dot4_64 subtrees + a top gft_add64, all iverilog-witnessed -> (9844, ...698).
    assert_eq!(
        tree8(&eight_lanes()),
        (9844, BigUint::from(2594073385365405698u64)),
        "8-lane tile tree = (9844, ...698)"
    );
}

#[test]
fn the_flat_fold_diverges_by_two_ulp_at_eight_lanes() {
    // The naive flat fold is 2 ULP low -- the gap widened from 1 ULP at 4 lanes.
    assert_eq!(
        flat8(&eight_lanes()),
        (9844, BigUint::from(2594073385365405696u64)),
        "flat fold = (9844, ...696)"
    );
    assert_ne!(
        flat8(&eight_lanes()),
        tree8(&eight_lanes()),
        "8-lane reduction order is load-bearing: the flat fold is a DIFFERENT value"
    );
}

#[test]
fn a_flat_fold_verifier_would_falsely_slash_the_honest_tile_result() {
    let honest = tree8(&eight_lanes());
    assert_ne!(
        flat8(&eight_lanes()),
        honest,
        "a verifier folding all 8 lanes flat would reject the honest tile result"
    );
}
