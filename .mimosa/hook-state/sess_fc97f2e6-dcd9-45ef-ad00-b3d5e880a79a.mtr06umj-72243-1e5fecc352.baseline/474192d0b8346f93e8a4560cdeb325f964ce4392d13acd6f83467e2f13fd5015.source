//! gft_range_coverage -- GF-T's balanced-ternary exponent buys DYNAMIC RANGE a same-width
//! binary float lacks. gft_task_accuracy measures ERROR (precision + clipping conflated);
//! this isolates the CLIPPING advantage: on a wide workload, how many operands can each format
//! REPRESENT at all? binary16 overflows past ~2^15.99 and underflows below 2^-24; GF-T16 spans
//! 2^+/-40, GF-T32 2^+/-364. So GF-T covers the whole band while binary16 clips a chunk, and a
//! higher rung's range strictly contains a lower one's -- the corner GF-T owns.

/// binary16 (IEEE half): representable iff zero, or |x| within [2^-24 (smallest subnormal),
/// 2^16 (just past the 65504 max)).
fn representable_binary16(x: f64) -> bool {
    if x == 0.0 {
        return true;
    }
    let a = x.abs();
    a >= 2f64.powi(-24) && a < 2f64.powi(16)
}

/// A GF-T rung with bias B represents exponents in [-B, B]: value (1+m/2^M) * 2^(offset - B),
/// offset in 0..2B, so |x| within [2^-B, 2^(B+1)). Range depends only on the bias (the mantissa
/// sets precision, not reach).
fn representable_gft(x: f64, bias: i32) -> bool {
    if x == 0.0 {
        return true;
    }
    let a = x.abs();
    a >= 2f64.powi(-bias) && a < 2f64.powi(bias + 1)
}

const GFT16_BIAS: i32 = 40;
const GFT32_BIAS: i32 = 364;

/// Deterministic wide workload (LCG): magnitudes log-uniform over exponents [-30, 30) -- past
/// binary16's reach on both ends, well inside GF-T16's.
fn wide_workload(n: usize) -> Vec<f64> {
    let mut s: u64 = 0xDEAD_BEEF_1234_5678;
    (0..n)
        .map(|_| {
            s = s
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let u = (s >> 33) as f64 / (1u64 << 31) as f64; // [0,1)
            let e = u * 60.0 - 30.0; // [-30, 30)
            2f64.powf(e)
        })
        .collect()
}

fn coverage(vals: &[f64], repr: impl Fn(f64) -> bool) -> f64 {
    vals.iter().filter(|&&x| repr(x)).count() as f64 / vals.len() as f64
}

#[test]
fn gft_covers_the_wide_band_where_binary16_clips() {
    let vals = wide_workload(4096);
    let cov_b16 = coverage(&vals, representable_binary16);
    let cov_g16 = coverage(&vals, |x| representable_gft(x, GFT16_BIAS));
    let cov_g32 = coverage(&vals, |x| representable_gft(x, GFT32_BIAS));

    assert_eq!(
        cov_g16, 1.0,
        "GF-T16 (2^+/-40) represents every operand in the 2^+/-30 band"
    );
    assert_eq!(
        cov_g32, 1.0,
        "GF-T32 (2^+/-364) represents every operand too"
    );
    assert!(
        cov_b16 < 1.0,
        "binary16 CLIPS part of the wide band (overflow > 2^15.99 / underflow < 2^-24)"
    );
    // The advantage is material, not a rounding artifact: binary16 loses a real fraction.
    assert!(
        cov_b16 < 0.9,
        "binary16 clips a substantial share of a 2^+/-30 workload ({cov_b16})"
    );
}

#[test]
fn a_higher_rung_range_contains_a_lower_one() {
    // Every value GF-T16 represents, GF-T32 also represents (range is monotone in bias).
    let vals = wide_workload(2048);
    for &x in &vals {
        if representable_gft(x, GFT16_BIAS) {
            assert!(
                representable_gft(x, GFT32_BIAS),
                "GF-T32 range contains GF-T16's"
            );
        }
    }
    // And GF-T32 reaches strictly farther: a value past GF-T16's 2^40 fits GF-T32's 2^364.
    let far = 2f64.powi(100);
    assert!(
        !representable_gft(far, GFT16_BIAS),
        "2^100 overflows GF-T16"
    );
    assert!(representable_gft(far, GFT32_BIAS), "but GF-T32 holds it");
    assert!(
        !representable_binary16(far),
        "and binary16 cannot come close"
    );
}
