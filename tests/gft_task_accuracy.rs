//! gft_task_accuracy -- TASK-LEVEL accuracy, not per-number roundtrip.
//!
//! `gft16_vs_binary16` measures how well each 16-bit format represents a SINGLE value.
//! This asks the decision-relevant question one brick up: when you round the OPERANDS of a
//! real computation (a dot product -- the atom of every matmul / attention / inference layer)
//! to each format, how far does the ANSWER drift from the exact f64 result?
//!
//! The workload is a sum of positive products x_i * w_i whose magnitudes are log-uniform over
//! a chosen exponent band (deterministic LCG -- reproducible, no deps). Two bands tell the
//! whole HONEST story:
//!   * narrow (2^-6..2^6): everything sits in every format's comfort zone. binary16 carries
//!     one more mantissa bit than GF-T16 (10 vs 9), so per-NUMBER it rounds finer -- yet
//!     MEASURED at the task level across this band the two come out statistically tied
//!     (~0.0017% each). We assert only that neither dominates, so we never overclaim EITHER
//!     direction: in-range, GF-T16 and binary16 are peers.
//!   * wide (2^-20..2^20): the band spills past binary16's 2^15.99 overflow / 2^-24 floor.
//!     binary16 can no longer represent the operands; GF-T16's 2^+/-40 range holds. This is
//!     the corner GF-T16 owns -- uniform coverage across a wide range, still finer than bf16.
//!
//! Pure Rust, no spec pipeline, no deps. Run: `cargo test --test gft_task_accuracy -- --nocapture`.

// ---- Roundtrip models copied VERBATIM from src/bin/gft16_vs_binary16.rs (same ruler). ----

const GFT16_EMAX: i32 = 40;
const GFT16_MANT: f64 = 512.0;
fn gft16_roundtrip(a: f64) -> f64 {
    if a <= 0.0 {
        return 0.0;
    }
    let mut e = a.log2().floor() as i32;
    if e < -GFT16_EMAX {
        e = -GFT16_EMAX;
    }
    if e > GFT16_EMAX {
        return f64::INFINITY;
    }
    let frac = a / 2f64.powi(e) - 1.0;
    let mut m = (frac * GFT16_MANT).round();
    let mut ee = e;
    if m >= GFT16_MANT {
        m = 0.0;
        ee += 1;
    }
    if ee > GFT16_EMAX {
        return f64::INFINITY;
    }
    (1.0 + m / GFT16_MANT) * 2f64.powi(ee)
}

const B16_MANT: f64 = 1024.0;
const B16_MAX: f64 = 65504.0;
fn binary16_roundtrip(a: f64) -> f64 {
    if a <= 0.0 {
        return 0.0;
    }
    if a > B16_MAX * (1.0 + 0.5 / B16_MANT) {
        return f64::INFINITY;
    }
    let e = a.log2().floor() as i32;
    if e >= -14 {
        let frac = a / 2f64.powi(e) - 1.0;
        let mut m = (frac * B16_MANT).round();
        let mut ee = e;
        if m >= B16_MANT {
            m = 0.0;
            ee += 1;
        }
        if ee > 15 {
            return f64::INFINITY;
        }
        (1.0 + m / B16_MANT) * 2f64.powi(ee)
    } else if e >= -25 {
        let m = (a / 2f64.powi(-14) * B16_MANT).round();
        if m < 1.0 {
            0.0
        } else {
            m / B16_MANT * 2f64.powi(-14)
        }
    } else {
        0.0
    }
}

const BF16_MANT: f64 = 128.0;
fn bf16_roundtrip(a: f64) -> f64 {
    if a <= 0.0 {
        return 0.0;
    }
    let e = a.log2().floor() as i32;
    if e > 127 {
        return f64::INFINITY;
    }
    if e < -126 {
        return 0.0;
    }
    let frac = a / 2f64.powi(e) - 1.0;
    let mut m = (frac * BF16_MANT).round();
    let mut ee = e;
    if m >= BF16_MANT {
        m = 0.0;
        ee += 1;
    }
    if ee > 127 {
        return f64::INFINITY;
    }
    (1.0 + m / BF16_MANT) * 2f64.powi(ee)
}

// ---- Workload: log-uniform positive magnitudes, deterministic LCG. ----

/// Deterministic [0,1) stream (PCG-style LCG constants). Reproducible => PROVEN, not lucky.
struct Lcg(u64);
impl Lcg {
    fn next01(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        // top 53 bits -> [0,1)
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }
}

/// n positive (x, w) pairs with log2-magnitudes uniform in [lo_exp, hi_exp].
fn workload(n: usize, lo_exp: f64, hi_exp: f64, seed: u64) -> Vec<(f64, f64)> {
    let mut g = Lcg(seed);
    (0..n)
        .map(|_| {
            let ex = lo_exp + (hi_exp - lo_exp) * g.next01();
            let ew = lo_exp + (hi_exp - lo_exp) * g.next01();
            (2f64.powf(ex), 2f64.powf(ew))
        })
        .collect()
}

/// Dot product with each operand pushed through `round` first; accumulate in f64
/// (the accumulator is not the unit under test -- operand REPRESENTATION is).
fn dot(pairs: &[(f64, f64)], round: fn(f64) -> f64) -> f64 {
    pairs.iter().map(|(x, w)| round(*x) * round(*w)).sum()
}

fn rel(approx: f64, exact: f64) -> f64 {
    if !approx.is_finite() {
        return f64::INFINITY;
    }
    (approx - exact).abs() / exact
}

fn measure(band: &str, lo: f64, hi: f64) -> (f64, f64, f64) {
    let pairs = workload(4096, lo, hi, 0x9E3779B97F4A7C15);
    let exact: f64 = pairs.iter().map(|(x, w)| x * w).sum();
    let g = rel(dot(&pairs, gft16_roundtrip), exact);
    let b = rel(dot(&pairs, binary16_roundtrip), exact);
    let f = rel(dot(&pairs, bf16_roundtrip), exact);
    let fmt = |v: f64| {
        if v.is_finite() {
            format!("{:>9.5}%", v * 100.0)
        } else {
            "  OVERFLOW".to_string()
        }
    };
    println!(
        "  {:<8} band 2^[{:+.0},{:+.0}]   GF-T16 {}   binary16 {}   bf16 {}",
        band,
        lo,
        hi,
        fmt(g),
        fmt(b),
        fmt(f)
    );
    (g, b, f)
}

#[test]
fn gft_task_level_accuracy() {
    println!("\nTASK-LEVEL dot-product relative error (4096 positive terms, exact f64 reference):");
    let (g_narrow, b_narrow, f_narrow) = measure("narrow", -6.0, 6.0);
    let (g_wide, b_wide, f_wide) = measure("wide", -20.0, 20.0);
    println!();

    // Precision: GF-T16 (9 mantissa bits) beats bf16 (7) in BOTH bands -- the uniform-precision edge.
    assert!(
        g_narrow < f_narrow,
        "GF-T16 should beat bf16 on precision (narrow): {g_narrow} !< {f_narrow}"
    );
    assert!(
        g_wide < f_wide,
        "GF-T16 should beat bf16 on precision (wide): {g_wide} !< {f_wide}"
    );

    // Honest caveat, LOCKED: in-range the two are PEERS at the task level (measured ~0.0017% each,
    // <5% apart). binary16 has one more mantissa bit, but that per-number edge washes out over a
    // 4096-term dot product. We assert a two-sided tie so the suite refuses to let us overclaim
    // EITHER format as more accurate in-range -- the honest story is "comparable".
    assert!(g_narrow < 2.0 * b_narrow && b_narrow < 2.0 * g_narrow,
        "in-range GF-T16 and binary16 should be task-level peers (within 2x): {g_narrow} vs {b_narrow}");

    // Range: the moment the workload needs dynamic range, binary16 collapses and GF-T16 holds.
    assert!(
        g_wide < b_wide,
        "GF-T16 should beat binary16 on the wide (range-bound) workload: {g_wide} !< {b_wide}"
    );
    assert!(
        b_wide.is_infinite() || b_wide > 10.0 * g_wide,
        "wide binary16 error should be catastrophic vs GF-T16"
    );
}
