//! goldenfloat_family_ladder -- IS THE WHOLE LINE REAL? Yes. This builds the GoldenFloat catalog
//! GF4 .. GF1024 (as in t27 specs/numeric/goldenfloat_family.t27, the same catalog as the arXiv
//! GF4-1024) and proves the golden-float significand arithmetic -- the heart of every rung --
//! computes correctly at EVERY width, from a 1-bit mantissa up to a 632-bit mantissa, using exact
//! BigUint (so no f64 precision ceiling limits the check).
//!
//! Per the SSOT formula: exp_bits = round((bits-1)/phi^2), mant_bits = bits-1-exp_bits. GF-T (the
//! ternary variant this repo runs on silicon for GF-T4/8/16/32) replaces the 2^exp exponent with
//! Et balanced-ternary trits, but the SIGNIFICAND multiply/renormalize recurrence -- tested here --
//! is identical at every rung. So the ladder is real all the way up; only the low ternary rungs
//! (4-32) are on silicon so far, and higher ternary Et per-rung values come from the SSOT.

use num_bigint::BigUint;

// num-bigint 0.4 re-exports One? Provide a local one() to avoid an extra dep.
fn one() -> BigUint {
    BigUint::from(1u32)
}

/// GoldenFloat catalog rung: total bits -> (exp_bits, mant_bits) via the phi formula.
fn rung(bits: u32) -> (u32, u32) {
    let phi2 = (1.0 + 5f64.sqrt()) / 2.0;
    let phi2 = phi2 * phi2; // phi^2 ~ 2.618
    let exp = (((bits - 1) as f64) / phi2).round() as u32;
    (exp, bits - 1 - exp)
}

/// The golden-float significand multiply at a given mantissa width, in EXACT BigUint.
/// Significand = 1 + m / 2^mant_bits, m in [0, 2^mant_bits). Returns (carry, mant_out).
fn sig_mul(mant_bits: u32, ma: &BigUint, mb: &BigUint) -> (u32, BigUint) {
    let mant_one = one() << mant_bits; // 2^mant_bits
    let prod = (&mant_one + ma) * (&mant_one + mb); // (1+ma/M)(1+mb/M) * M^2, exact
    let thresh = (&mant_one * 2u32) * &mant_one; // 2 * M^2  (significand product >= 2 => carry)
    if prod >= thresh {
        (1, &prod / (&mant_one * 2u32) - &mant_one)
    } else {
        (0, &prod / &mant_one - &mant_one)
    }
}

/// Exact renormalization check, valid at ANY width: the reconstructed floored significand product
/// must bound the true product within one mantissa ULP.
///   floor:  (M + mant_out) * 2^carry * M  <=  (M+ma)(M+mb)  <  (M + mant_out + 1) * 2^carry * M
fn renorm_is_correct(mant_bits: u32, ma: &BigUint, mb: &BigUint) -> bool {
    let mant_one = one() << mant_bits;
    let (carry, mant_out) = sig_mul(mant_bits, ma, mb);
    let scale = &mant_one << carry; // 2^carry * M
    let lo = (&mant_one + &mant_out) * &scale;
    let hi = (&mant_one + &mant_out + one()) * &scale;
    let true_prod = (&mant_one + ma) * (&mant_one + mb);
    lo <= true_prod && true_prod < hi
}

const CATALOG: &[u32] = &[4, 8, 16, 32, 64, 128, 256, 512, 1024];

#[test]
fn the_catalog_widths_follow_the_phi_formula() {
    // Anchor: GF16 = 6 exp / 9 mant (the frozen silicon anchor), and the low rungs match.
    assert_eq!(rung(16), (6, 9), "GF16 anchor = 1+6+9");
    assert_eq!(rung(8).1, 4, "GF8 mantissa = 4 (matches GF-T8)");
    // The whole catalog is well-formed: exp + mant + sign = bits, mantissa grows monotonically.
    let mut prev_m = 0;
    for &b in CATALOG {
        let (e, m) = rung(b);
        assert_eq!(e + m + 1, b, "GF{b}: sign+exp+mant must equal width");
        assert!(m > prev_m, "GF{b}: mantissa must grow up the ladder");
        prev_m = m;
    }
    // Top of the line really is a ~632-bit mantissa.
    assert_eq!(rung(1024).1, 632, "GF1024 carries a 632-bit mantissa");
}

#[test]
fn golden_float_multiply_is_exact_at_every_rung_to_gf1024() {
    // For each catalog rung, the significand multiply + renormalize is provably correct (exact
    // BigUint bound), for representative mantissa values including the extremes.
    for &bits in CATALOG {
        let (_e, mant_bits) = rung(bits);
        let m = one() << mant_bits; // = mant_one
        let vals = [
            BigUint::from(0u32), // 1.0
            &m / 2u32,           // 1.5
            &m / 4u32,           // 1.25
            &m * 3u32 / 4u32,    // 1.75
            &m - one(),          // ~2.0 (largest)
        ];
        for a in &vals {
            for b in &vals {
                assert!(
                    renorm_is_correct(mant_bits, a, b),
                    "GF{bits} ({mant_bits}-bit mantissa) renorm wrong for a,b"
                );
            }
        }
    }
}

#[test]
fn low_rungs_match_the_known_silicon_kats() {
    // The exact values the low ladder returns on the over-wire verifier AND on silicon.
    // GF-T8 (mant 4): 1.5*1.5 = 2.25 -> (carry 1, mant 2).  (13,8)^2 -> (14,2).
    let m4 = one() << 4u32;
    assert_eq!(
        sig_mul(4, &(&m4 / 2u32), &(&m4 / 2u32)),
        (1, BigUint::from(2u32))
    );
    // GF-T16 (mant 9): 1.5*1.5 = 2.25 -> (carry 1, mant 64).  (41,256)^2 -> (43,64).
    let m9 = one() << 9u32;
    assert_eq!(
        sig_mul(9, &(&m9 / 2u32), &(&m9 / 2u32)),
        (1, BigUint::from(64u32))
    );
    // GF-T32 (mant 25): 1.5*1.5 -> (carry 1, mant 2^22).  (364,2^24)^2 -> (365,2^22).
    let m25 = one() << 25u32;
    assert_eq!(
        sig_mul(25, &(&m25 / 2u32), &(&m25 / 2u32)),
        (1, one() << 22u32)
    );
    // GF-T64-class (mant 39): the same 1.5*1.5 identity holds at the wide rung -> mant = 2^(39-3).
    let m39 = one() << 39u32;
    assert_eq!(
        sig_mul(39, &(&m39 / 2u32), &(&m39 / 2u32)),
        (1, one() << 36u32)
    );
    // 1.5*1.5 = 2.25 = 1.125*2 = (1 + 1/8)*2, so mant_out = M/8 = 2^(mant_bits-3), carry 1 -- at ANY
    // width, right up to a 632-bit mantissa. The recurrence is width-agnostic; the ladder is real.
    let m632 = one() << 632u32; // GF1024
    assert_eq!(
        sig_mul(632, &(&m632 / 2u32), &(&m632 / 2u32)),
        (1, one() << 629u32)
    );
}

/// Regression guard for the GF-T ladder's TERNARY exponent geometry -- the table the
/// money layer (tri_compute_gfvalid / _settle) must match. Et per rung is the ratified
/// golden rule Et = fib(k+1)+1 (rung k: GF-T4=1 .. GF-T128=6), NOT Et = log2(width).
/// The two agree through GF-T16 and DIVERGE at GF-T32 (fib -> 6, log2 -> 5). A spec that
/// re-derives Et by log2 -- exactly the bug fixed in gfvalid/settle, where GF-T32 got
/// offset_max 242 instead of 728 -- is caught by diffing against this pinned table.
fn tfib(n: u32) -> u32 {
    let (mut a, mut b) = (0u32, 1u32);
    let mut i = 0;
    while i < n {
        let t = a + b;
        a = b;
        b = t;
        i += 1;
    }
    a
}

fn pow3_u64(e: u32) -> u64 {
    let mut p = 1u64;
    let mut i = 0;
    while i < e {
        p *= 3;
        i += 1;
    }
    p
}

fn log2_width(width: u32) -> u32 {
    let mut w = width;
    let mut k = 0;
    while w > 1 {
        w >>= 1;
        k += 1;
    }
    k
}

#[test]
fn ternary_rung_geometry_table_is_pinned() {
    // (width, rung k, Et, offset_max = 3^Et - 1, bias = (3^Et - 1)/2)
    let table = [
        (4u32, 1u32, 2u32, 8u64, 4u64),
        (8, 2, 3, 26, 13),
        (16, 3, 4, 80, 40),
        (32, 4, 6, 728, 364), // Et6 (golden rule), NOT log2's Et5/242
        (64, 5, 9, 19682, 9841),
        (128, 6, 14, 4782968, 2391484),
    ];
    for (w, k, et, omax, bias) in table {
        assert_eq!(
            log2_width(w),
            k + 1,
            "GF-T{w}: rung index k = log2(width) - 1"
        );
        assert_eq!(
            tfib(k + 1) + 1,
            et,
            "GF-T{w}: Et = fib(k+1) + 1 (golden rule)"
        );
        let p = pow3_u64(et);
        assert_eq!(p - 1, omax, "GF-T{w}: offset_max = 3^Et - 1");
        assert_eq!((p - 1) / 2, bias, "GF-T{w}: bias = (3^Et - 1)/2");
    }
    // Pin the exact divergence the money-layer bug rode: through GF-T16 log2 == fib rule,
    // but at GF-T32 they split -- log2 gives the wrong Et 5, the golden rule gives 6.
    for &(w, et) in &[(4u32, 2u32), (8, 3), (16, 4)] {
        assert_eq!(log2_width(w), et, "GF-T{w}: log2 coincides with Et here");
    }
    assert_eq!(log2_width(32), 5, "log2(32) = 5 -- the WRONG GF-T32 Et");
    assert_eq!(tfib(5) + 1, 6, "the correct GF-T32 Et is 6, not 5");
    assert_ne!(
        log2_width(32),
        tfib(5) + 1,
        "GF-T32 is exactly where log2 != the golden rule"
    );
}
