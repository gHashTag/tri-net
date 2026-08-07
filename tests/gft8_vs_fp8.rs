//! gft8_vs_fp8 -- GF-T8 against the two industry 8-bit floats (OCP FP8: E4M3, E5M2). The
//! existing accuracy tests pit GF-T16 against binary16/bf16; this places the ternary BOTTOM-half
//! rung against the formats it actually competes with for edge inference. GF-T8 spends its 8 bits
//! as sign + 3 balanced-ternary exponent trits (range 2^+/-13) + 4 mantissa bits. FP8-E4M3 is
//! 4-exp/3-mant (finer range, only 3 mantissa bits); E5M2 is 5-exp/2-mant (widest range, just 2
//! mantissa bits). So GF-T8 carries MORE mantissa than either -- within a shared range it is the
//! most precise 8-bit float, and its 2^+/-13 range still outreaches E4M3.
//!
//! All formats use round-to-nearest (comparing REPRESENTATIONAL precision, not a rounding mode),
//! clamped to each format's normal exponent range.

/// Round x to `mant_bits` mantissa bits (round-to-nearest), clamped to [2^min_e, 2^(max_e+1)).
fn quantize(x: f64, mant_bits: u32, min_e: i32, max_e: i32) -> f64 {
    if x == 0.0 {
        return 0.0;
    }
    let s = x.signum();
    let a = x.abs();
    // clamp to the format's normal range
    let lo = 2f64.powi(min_e);
    let hi = 2f64.powi(max_e + 1);
    if a >= hi {
        return s * (hi - hi * 2f64.powi(-(mant_bits as i32))); // saturate to the max representable
    }
    if a < lo {
        return 0.0; // flush denormals below the normal range (fair, coarse floor)
    }
    let e = a.log2().floor();
    let scale = 2f64.powf(e);
    let m = a / scale; // [1,2)
    let levels = 2f64.powi(mant_bits as i32);
    let mq = (m * levels).round() / levels; // round-to-nearest mantissa
    s * mq * scale
}

// (mant_bits, min normal exp, max normal exp)
const GFT8: (u32, i32, i32) = (4, -13, 13); // 3 balanced-ternary trits -> offset +/-13
const FP8_E4M3: (u32, i32, i32) = (3, -6, 8); // OCP E4M3: max normal 448 = 1.75*2^8
const FP8_E5M2: (u32, i32, i32) = (2, -14, 15); // OCP E5M2: max normal 57344 = 1.75*2^15

fn q(x: f64, f: (u32, i32, i32)) -> f64 {
    quantize(x, f.0, f.1, f.2)
}

fn workload(n: usize, lo_e: f64, hi_e: f64, seed: u64) -> Vec<(f64, f64)> {
    let mut s = seed;
    let mut next = || {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let u = (s >> 33) as f64 / (1u64 << 31) as f64;
        let e = lo_e + u * (hi_e - lo_e);
        let mant = 1.0 + ((s >> 11) & 0xFFFFF) as f64 / (1u64 << 20) as f64;
        mant * 2f64.powf(e)
    };
    (0..n).map(|_| (next(), next())).collect()
}

fn dot_q(terms: &[(f64, f64)], f: (u32, i32, i32)) -> f64 {
    terms.iter().map(|&(a, b)| q(a, f) * q(b, f)).sum()
}
fn exact(terms: &[(f64, f64)]) -> f64 {
    terms.iter().map(|&(a, b)| a * b).sum()
}
fn rel(approx: f64, ex: f64) -> f64 {
    ((approx - ex) / ex).abs()
}

#[test]
fn gft8_is_the_most_precise_8bit_float_in_a_shared_range() {
    // Moderate band (2^-4..2^4) sits inside all three formats' normal range -> pure precision.
    let terms = workload(256, -4.0, 4.0, 0xA5A5_1234);
    let ex = exact(&terms);
    let e_gft8 = rel(dot_q(&terms, GFT8), ex);
    let e_e4m3 = rel(dot_q(&terms, FP8_E4M3), ex);
    let e_e5m2 = rel(dot_q(&terms, FP8_E5M2), ex);
    assert!(
        e_gft8 < e_e4m3,
        "GF-T8 (4 mant) beats E4M3 (3 mant): {e_gft8} !< {e_e4m3}"
    );
    assert!(
        e_e4m3 < e_e5m2,
        "E4M3 (3 mant) beats E5M2 (2 mant): {e_e4m3} !< {e_e5m2}"
    );
}

#[test]
fn gft8_outreaches_e4m3_on_range() {
    // A value past E4M3's 448 max but inside GF-T8's 2^13: GF-T8 holds it, E4M3 saturates.
    let big = 2f64.powi(11); // 2048, > 448
    assert!(
        q(big, GFT8) > 1000.0,
        "GF-T8 represents 2^11 (within 2^13 range)"
    );
    assert!(
        q(big, FP8_E4M3) <= 448.0,
        "E4M3 saturates 2^11 to its 448 ceiling"
    );
    // On a wide band, E4M3 clips the top while GF-T8 does not -> GF-T8's error is lower.
    let terms = workload(256, -4.0, 12.0, 0xBEEF_9999);
    let ex = exact(&terms);
    assert!(
        rel(dot_q(&terms, GFT8), ex) < rel(dot_q(&terms, FP8_E4M3), ex),
        "on a 2^12-reaching workload GF-T8 beats E4M3 (range advantage)"
    );
}
