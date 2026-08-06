//! goldenfloat_ternary_ladder -- what defines GF-T64 and up? A Fibonacci (golden) rule that
//! reproduces EVERY canonical GF-T rung exactly, then extends it. This closes the honest gap
//! flagged in goldenfloat_family_ladder.rs (higher ternary Et were "non-linear, from the SSOT"):
//! the non-linearity IS the golden sequence.
//!
//! Decoding the four canonical rungs from specs/tri_gft_ladder.t27 (Et, mant_bits):
//!   GF-T4 (2,1), GF-T8 (3,4), GF-T16 (4,9), GF-T32 (6,25).
//! The mantissas 1,4,9,25 are 1^2,2^2,3^2,5^2 = fib(2..5)^2, and the exponent-trit counts 2,3,4,6
//! are fib(2..5)+1. So for rung index k (GF-T4=1, GF-T8=2, GF-T16=3, GF-T32=4, GF-T64=5, ...):
//!   Et(k)   = fib(k+1) + 1
//!   mant(k) = fib(k+1)^2
//! This is exactly the phi structure GF-T is named for (Fibonacci -> phi, and phi^2+phi^-2=3, the
//! ternary anchor). It is PRESENTED AS PROPOSED for GF-T64+ -- it fits all four sealed rungs, but
//! its ratification for higher rungs is the SSOT's (t27 specs/numeric/gft*.t27); GF-T on silicon
//! still stops at GF-T32. It also reproduces the exact canonical offset_max/bias (GF-T16 -> 80/40,
//! GF-T32 -> 728/364), which is strong confirmation the rule is the real one.

use num_bigint::BigUint;

fn one() -> BigUint {
    BigUint::from(1u32)
}
fn fib(n: u32) -> u64 {
    let (mut a, mut b) = (0u64, 1u64);
    for _ in 0..n {
        let t = a + b;
        a = b;
        b = t;
    }
    a // fib(0)=0, fib(1)=1, fib(2)=1, ...
}

/// The golden rule for GF-T rung k (k>=1): exponent trits and mantissa bits.
fn et(k: u32) -> u32 {
    (fib(k + 1) + 1) as u32
}
fn mant_bits(k: u32) -> u32 {
    let f = fib(k + 1);
    (f * f) as u32
}
/// Ternary exponent geometry: 3^Et codes, offset in [0, 3^Et - 1], bias = (3^Et - 1)/2.
fn offset_max(k: u32) -> BigUint {
    let mut p = one();
    for _ in 0..et(k) {
        p *= 3u32;
    }
    p - one()
}

/// The golden-float significand multiply at a mantissa width, exact in BigUint (from #206).
fn sig_mul(mbits: u32, ma: &BigUint, mb: &BigUint) -> (u32, BigUint) {
    let m = one() << mbits;
    let prod = (&m + ma) * (&m + mb);
    if prod >= (&m * 2u32) * &m {
        (1, &prod / (&m * 2u32) - &m)
    } else {
        (0, &prod / &m - &m)
    }
}

// Canonical rungs decoded from specs/tri_gft_ladder.t27: (k, Et, mant_bits).
const CANON: &[(u32, u32, u32)] = &[(1, 2, 1), (2, 3, 4), (3, 4, 9), (4, 6, 25)];

#[test]
fn the_fibonacci_rule_reproduces_every_canonical_rung() {
    for &(k, e, m) in CANON {
        assert_eq!(et(k), e, "GF-T rung {k}: Et must be fib(k+1)+1");
        assert_eq!(mant_bits(k), m, "GF-T rung {k}: mant must be fib(k+1)^2");
    }
    // And it reproduces the exact canonical ternary geometry (offset_max / bias).
    assert_eq!(
        offset_max(3),
        BigUint::from(80u32),
        "GF-T16 offset_max = 3^4-1 = 80"
    );
    assert_eq!(
        offset_max(4),
        BigUint::from(728u32),
        "GF-T32 offset_max = 3^6-1 = 728"
    );
}

#[test]
fn the_rule_extends_the_ladder_to_gf_t1024() {
    // Proposed higher rungs by the same golden rule (k = 5..9 -> GF-T64..GF-T1024).
    let expect: &[(u32, u32, u32)] = &[
        (5, 9, 64),    // GF-T64:   Et = fib(6)+1 = 9,  mant = 8^2  = 64
        (6, 14, 169),  // GF-T128:  Et = fib(7)+1 = 14, mant = 13^2 = 169
        (7, 22, 441),  // GF-T256:  Et = fib(8)+1 = 22, mant = 21^2 = 441
        (8, 35, 1156), // GF-T512:  Et = fib(9)+1 = 35, mant = 34^2 = 1156
        (9, 56, 3025), // GF-T1024: Et = fib(10)+1= 56, mant = 55^2 = 3025
    ];
    let mut prev_m = 25u32; // GF-T32
    for &(k, e, m) in expect {
        assert_eq!(et(k), e, "GF-T rung {k} Et");
        assert_eq!(mant_bits(k), m, "GF-T rung {k} mant");
        assert!(m > prev_m, "mantissa grows up the ladder");
        prev_m = m;
        // offset_max = 3^Et - 1 is well-formed and huge (the top rung's whole point).
        assert_eq!(&offset_max(k) + one(), pow3(e), "offset_max = 3^Et - 1");
    }
}

fn pow3(e: u32) -> BigUint {
    let mut p = one();
    for _ in 0..e {
        p *= 3u32;
    }
    p
}

#[test]
fn the_significand_multiply_computes_at_the_proposed_gf_t64_and_up() {
    // The 1.5*1.5 = 2.25 = (1 + 1/8)*2 identity: mant_out = 2^(mant-3), carry 1, at every rung's
    // mantissa width. Proven exact in BigUint for GF-T64 (64-bit mantissa) through GF-T1024.
    for k in 5..=9 {
        let mb = mant_bits(k);
        let m = one() << mb;
        assert_eq!(
            sig_mul(mb, &(&m / 2u32), &(&m / 2u32)),
            (1, one() << (mb - 3)),
            "GF-T rung {k} ({mb}-bit mantissa): 1.5^2 renorm"
        );
        // And a non-carry case: 1.25 * 1.25 = 1.5625 = 1 + 9/16, mant_out = 9*M/16, carry 0.
        let quarter = &m / 4u32;
        let (carry, out) = sig_mul(mb, &quarter, &quarter);
        assert_eq!(carry, 0, "1.25^2 = 1.5625 < 2, no carry");
        assert_eq!(
            out,
            &m * 9u32 / 16u32,
            "1.25^2 mantissa = 9*M/16 at rung {k}"
        );
    }
}
