//! gft_ladder_accuracy -- the LADDER'S CORE PROMISE, numerically: a higher rung computes a
//! MORE accurate answer. GF-T is a "precision <-> cost dial", so on a fixed workload the
//! relative error of a dot product must DECREASE as the rung's mantissa width grows
//! (GF-T4 -> GF-T8 -> GF-T16 -> GF-T32: mant_bits 1, 4, 9, 25 per tri_gft_ladder). Every
//! other test fixes one rung (gft_dot_oracle / gft_task_accuracy are GF-T16); this one
//! sweeps the rungs and proves monotone improvement -- the reason the ladder exists.
//!
//! Model: a value is (1 + m/2^M) * 2^e with an M-bit mantissa. GF-T rounds toward zero on
//! the mantissa grid (cf. the RTZ in fpga/gft/gft_mul4 -- 1.5*1.5 = 2.25 -> 2.0 at M=1).
//! A dot product folds each RTZ-rounded product into an RTZ-rounded accumulator; the exact
//! f64 dot is the reference. RTZ truncation is one-signed, so more bits strictly help.

/// Round a positive value toward zero onto an M-bit-mantissa grid: (1 + m/2^M) * 2^e.
fn quantize_rtz(x: f64, mant_bits: u32) -> f64 {
    if x <= 0.0 {
        return 0.0;
    }
    let e = x.log2().floor();
    let scale = 2f64.powf(e); // x in [scale, 2*scale)
    let m = x / scale; // in [1, 2)
    let levels = 2f64.powi(mant_bits as i32);
    ((m * levels).floor() / levels) * scale // truncate the mantissa (RTZ)
}

/// A dot product of positive terms computed entirely on the rung's M-bit grid: operands,
/// each product, and the running accumulator are all RTZ-rounded to M mantissa bits.
fn dot_at_rung(terms: &[(f64, f64)], mant_bits: u32) -> f64 {
    let mut acc = 0.0f64;
    for &(a, b) in terms {
        let p = quantize_rtz(
            quantize_rtz(a, mant_bits) * quantize_rtz(b, mant_bits),
            mant_bits,
        );
        acc = quantize_rtz(acc + p, mant_bits);
    }
    acc
}

fn exact_dot(terms: &[(f64, f64)]) -> f64 {
    terms.iter().map(|&(a, b)| a * b).sum()
}

fn rel_err(approx: f64, exact: f64) -> f64 {
    ((approx - exact) / exact).abs()
}

/// Deterministic positive workload (LCG, no deps): 64 products with operands log-uniform
/// over a moderate exponent band, so every rung's exponent range holds them.
fn workload() -> Vec<(f64, f64)> {
    let mut s: u64 = 0x1234_5678_9ABC_DEF0;
    let mut next = || {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        // map to [2^-4, 2^4): exponent in [-4,4), mantissa in [1,2)
        let bits = (s >> 33) as f64 / (1u64 << 31) as f64; // [0,1)
        let e = (bits * 8.0).floor() - 4.0; // -4..3
        let m = 1.0 + ((s >> 11) & 0xFFFFF) as f64 / (1u64 << 20) as f64; // [1,2)
        m * 2f64.powf(e)
    };
    (0..64).map(|_| (next(), next())).collect()
}

const RUNGS: [(&str, u32); 4] = [("GF-T4", 1), ("GF-T8", 4), ("GF-T16", 9), ("GF-T32", 25)];

#[test]
fn accuracy_improves_monotonically_up_the_ladder() {
    let terms = workload();
    let exact = exact_dot(&terms);
    assert!(exact > 0.0, "positive workload has a positive exact dot");

    let errs: Vec<(f64, u32)> = RUNGS
        .iter()
        .map(|&(_, m)| (rel_err(dot_at_rung(&terms, m), exact), m))
        .collect();

    // Monotone non-increasing error as mantissa width grows (RTZ truncation is one-signed,
    // so more bits never hurt and generally strictly help on a 64-term sum).
    for w in errs.windows(2) {
        assert!(
            w[1].0 <= w[0].0,
            "rung with {} mant bits must not be LESS accurate than {} bits ({} vs {})",
            w[1].1,
            w[0].1,
            w[1].0,
            w[0].0
        );
    }
    // And the top rung is dramatically better than the bottom -- the dial has real range.
    let (err_gft4, err_gft32) = (errs[0].0, errs[3].0);
    assert!(err_gft4 > err_gft32, "GF-T4 is coarser than GF-T32");
    assert!(
        err_gft32 * 100.0 < err_gft4,
        "GF-T32 error is <1% of GF-T4's -- the ladder delivers"
    );
}

#[test]
fn each_rung_stays_within_its_mantissa_bound() {
    // A single product's relative error is bounded by the mantissa quantum 2^-M (RTZ), so a
    // rung is never wildly wrong: GF-T16 (M9) keeps a single term within ~2^-9, GF-T32 tighter.
    let a = 1.6180339887f64; // phi -- an irrational the grid cannot represent exactly
    for &(name, m) in RUNGS.iter() {
        let q = quantize_rtz(a, m);
        let bound = 2f64.powi(-(m as i32));
        assert!(
            (a - q) / a <= bound && q <= a,
            "{name}: RTZ quantum keeps the value within 2^-{m} below the true value"
        );
    }
}
