//! gft16_vs_binary16 -- MEASURE GF-T16's dynamic-range advantage over IEEE binary16.
//!
//! Both are 16-bit floats. binary16 = [s | 5 binary exp (bias 15) | 10 mantissa]:
//! normals 2^-14..2^15, subnormals to 2^-24, overflow past 65504. GF-T16 =
//! [s | 4 balanced-ternary exp trits | 9 mantissa] = (1+M/512)*2^e with e in [-40, 40]
//! (81 exponent codes vs binary16's 32). So GF-T16 trades one mantissa bit for a MUCH
//! wider exponent range. This harness encodes/decodes real values through each format and
//! reports the measured dynamic range, the worst-case relative error inside each format's
//! range, and how much of a 2^-40..2^40 sweep each represents finitely. No claims -- the
//! numbers below are printed by the run. Pure Rust (no deps, not the spec pipeline).
#![allow(dead_code)]

// ---- GF-T16: (1 + M/512) * 2^e, e in [-40, 40], M in [0, 511]. ----
const GFT16_EMAX: i32 = 40;
const GFT16_MANT: f64 = 512.0;

/// Round a positive value to the nearest GF-T16, return the decoded value (or None if 0).
fn gft16_roundtrip(a: f64) -> f64 {
    if a <= 0.0 { return 0.0; }
    let mut e = a.log2().floor() as i32;
    if e < -GFT16_EMAX { e = -GFT16_EMAX; }        // saturate low
    if e > GFT16_EMAX { return f64::INFINITY; }    // above the largest exponent -> overflow
    let frac = a / 2f64.powi(e) - 1.0;             // in [0, 1)
    let mut m = (frac * GFT16_MANT).round();
    let mut ee = e;
    if m >= GFT16_MANT { m = 0.0; ee += 1; }        // mantissa carry
    if ee > GFT16_EMAX { return f64::INFINITY; }
    (1.0 + m / GFT16_MANT) * 2f64.powi(ee)
}

// ---- IEEE binary16 (half): 5-bit exp bias 15, 10-bit mantissa. ----
const B16_MANT: f64 = 1024.0;
const B16_MAX: f64 = 65504.0;                       // (1 + 1023/1024) * 2^15

/// Round a positive value to the nearest binary16, return the decoded value.
fn binary16_roundtrip(a: f64) -> f64 {
    if a <= 0.0 { return 0.0; }
    if a > B16_MAX * (1.0 + 0.5 / B16_MANT) { return f64::INFINITY; } // overflow
    let e = a.log2().floor() as i32;
    if e >= -14 {
        // normal
        let frac = a / 2f64.powi(e) - 1.0;
        let mut m = (frac * B16_MANT).round();
        let mut ee = e;
        if m >= B16_MANT { m = 0.0; ee += 1; }
        if ee > 15 { return f64::INFINITY; }
        (1.0 + m / B16_MANT) * 2f64.powi(ee)
    } else if e >= -25 {
        // subnormal: value = (M/1024) * 2^-14, M in [1, 1023], smallest 2^-24
        let m = (a / 2f64.powi(-14) * B16_MANT).round();
        if m < 1.0 { 0.0 } else { m / B16_MANT * 2f64.powi(-14) }
    } else {
        0.0 // underflow
    }
}

fn rel_err(rt: f64, a: f64) -> f64 {
    if !rt.is_finite() || rt == 0.0 { f64::INFINITY } else { (rt - a).abs() / a }
}

fn main() {
    // Sweep 2^-40 .. 2^40, several points per octave, at non-power-of-two offsets.
    let (mut n, mut g_ok, mut b_ok) = (0u32, 0u32, 0u32);
    let (mut g_worst, mut b_worst_normal, mut b_worst_subnormal) = (0f64, 0f64, 0f64);
    let steps_per_octave = 7;
    let mut k = -40 * steps_per_octave;
    while k <= 40 * steps_per_octave {
        let a = 2f64.powf(k as f64 / steps_per_octave as f64) * 1.031; // off the exact powers
        n += 1;
        let ge = rel_err(gft16_roundtrip(a), a);
        let be = rel_err(binary16_roundtrip(a), a);
        if ge.is_finite() { g_ok += 1; if ge > g_worst { g_worst = ge; } }
        if be.is_finite() {
            b_ok += 1;
            // binary16 normals are >= 2^-14; below that it is subnormal (precision degrades).
            if a >= 2f64.powi(-14) { if be > b_worst_normal { b_worst_normal = be; } }
            else if be > b_worst_subnormal { b_worst_subnormal = be; }
        }
        k += 1;
    }

    // Representable range (min positive / max finite), measured.
    let gft_min = gft16_roundtrip(2f64.powi(-GFT16_EMAX));
    let gft_max = (1.0 + 511.0 / GFT16_MANT) * 2f64.powi(GFT16_EMAX);

    println!("GF-T16 vs IEEE binary16 -- both 16-bit, measured over a 2^-40..2^40 sweep ({} points):", n);
    println!();
    println!("  dynamic range (min positive .. max finite):");
    println!("    GF-T16    : {:.3e} .. {:.3e}   (spread ~2^{:.0})", gft_min, gft_max, (gft_max / gft_min).log2());
    println!("    binary16  : {:.3e} .. {:.3e}   (spread ~2^{:.0})", 2f64.powi(-24), B16_MAX, (B16_MAX / 2f64.powi(-24)).log2());
    println!();
    println!("  worst-case relative error:");
    println!("    GF-T16 (whole range)     : {:.3}%   (uniform -- 9-bit mantissa everywhere, no subnormals)", g_worst * 100.0);
    println!("    binary16 (normals)       : {:.3}%   (10-bit mantissa -- ~2x finer than GF-T16 where it applies)", b_worst_normal * 100.0);
    println!("    binary16 (subnormals)    : {:.1}%   (relative precision COLLAPSES near the 2^-24 underflow floor)", b_worst_subnormal * 100.0);
    println!();
    println!("  of the {} sweep points, represented FINITELY (no overflow/underflow):", n);
    println!("    GF-T16    : {} / {}  ({:.0}%)", g_ok, n, 100.0 * g_ok as f64 / n as f64);
    println!("    binary16  : {} / {}  ({:.0}%)", b_ok, n, 100.0 * b_ok as f64 / n as f64);
    println!();
    println!("  => GF-T16 trades ~2x mantissa error for ~2^{:.0}x more dynamic range at the SAME 16 bits;",
        (gft_max / gft_min).log2() - (B16_MAX / 2f64.powi(-24)).log2());
    println!("     binary16 overflows past 6.6e4 and underflows below ~6e-8, where GF-T16 stays finite and accurate.");

    // Sanity: the format-defining round-trips are exact on representable values.
    assert!((gft16_roundtrip(1.5) - 1.5).abs() < 1e-12, "GF-T16 represents 1.5 exactly");
    assert!((binary16_roundtrip(1.5) - 1.5).abs() < 1e-12, "binary16 represents 1.5 exactly");
    assert_eq!(binary16_roundtrip(1.0e6), f64::INFINITY, "binary16 overflows at 1e6");
    assert!(gft16_roundtrip(1.0e6).is_finite(), "GF-T16 is finite at 1e6");
    assert!(gft16_roundtrip(1.0e-11).is_finite() && binary16_roundtrip(1.0e-11) == 0.0, "GF-T16 finite, binary16 underflows at 1e-11");
    println!("\nOK: round-trips exact on representable values; the range/accuracy gap is measured above.");
}
