//! gft_rmsnorm_accuracy -- TASK-LEVEL accuracy on RMSNorm (the normalization atom of LLaMA-class
//! transformers), the mirror image of the softmax boundary.
//!
//! RMSNorm divides activations by rms = sqrt(mean(x_i^2)). Squaring DOUBLES the dynamic range of
//! the intermediates: an activation at 2^k lands its square at 2^(2k). Every term contributes to
//! the mean (no mass concentration to hide behind, unlike softmax), so a format that cannot hold
//! the squared range corrupts the norm for the WHOLE vector. This is exactly the shape where
//! GF-T16's 2^+/-40 range beats binary16's 2^15.99 ceiling / 2^-24 floor.
//!
//! Model: round each activation to the format, square it, round the SQUARE to the format (the
//! squared intermediate is where range bites), accumulate the mean in f64, take sqrt. Report the
//! relative error of the rms scalar vs an exact f64 reference. Two activation bands (deterministic
//! LCG). We model the square as format-resident to isolate the format's raw range capability --
//! production kernels often accumulate RMSNorm in fp32 for exactly this reason (cf. FlashAttention).
//!
//! Net with the sibling tests: gft_task_accuracy (dot product) + this (RMSNorm) = GF-T16 WINS
//! range-bound accumulation; gft_softmax_accuracy = GF-T16 LOSES precision-bound, mass-concentrated
//! softmax. Together they draw the honest boundary of the format.
//!
//! Pure Rust, no deps, no Python. Roundtrip models copied verbatim from src/bin/gft16_vs_binary16.rs.
//! Run: `cargo test --test gft_rmsnorm_accuracy -- --nocapture`.

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

// ---- Workload: activation magnitudes log-uniform over [2^-hi, 2^hi]. ----

struct Lcg(u64);
impl Lcg {
    fn next01(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }
}

fn activations(n: usize, hi_exp: f64, seed: u64) -> Vec<f64> {
    let mut g = Lcg(seed);
    (0..n)
        .map(|_| 2f64.powf(-hi_exp + 2.0 * hi_exp * g.next01()))
        .collect()
}

/// rms = sqrt(mean(x^2)) with each activation AND its square pushed through `round`.
fn rms_fmt(xs: &[f64], round: fn(f64) -> f64) -> f64 {
    let x = xs.iter().map(|&v| round(v));
    let sumsq: f64 = x.map(|v| round(v * v)).sum();
    (sumsq / xs.len() as f64).sqrt()
}

fn rms_exact(xs: &[f64]) -> f64 {
    (xs.iter().map(|&v| v * v).sum::<f64>() / xs.len() as f64).sqrt()
}

fn rel(approx: f64, exact: f64) -> f64 {
    if !approx.is_finite() {
        return f64::INFINITY;
    }
    (approx - exact).abs() / exact
}

fn measure(band: &str, hi: f64) -> (f64, f64, f64) {
    let xs = activations(1024, hi, 0x9E3779B97F4A7C15);
    let exact = rms_exact(&xs);
    let g = rel(rms_fmt(&xs, gft16_roundtrip), exact);
    let b = rel(rms_fmt(&xs, binary16_roundtrip), exact);
    let f = rel(rms_fmt(&xs, bf16_roundtrip), exact);
    let fmt = |v: f64| {
        if v.is_finite() {
            format!("{:>9.5}%", v * 100.0)
        } else {
            "  OVERFLOW".to_string()
        }
    };
    println!(
        "  {:<7} x in 2^[{:+.0},{:+.0}] (x^2 to 2^{:.0})   GF-T16 {}   binary16 {}   bf16 {}",
        band,
        -hi,
        hi,
        2.0 * hi,
        fmt(g),
        fmt(b),
        fmt(f)
    );
    (g, b, f)
}

#[test]
fn gft_rmsnorm_task_accuracy() {
    println!("\nTASK-LEVEL RMSNorm rms-scalar relative error vs exact f64 (1024 activations):");
    let (g_n, b_n, _f_n) = measure("narrow", 3.0);
    let (g_w, b_w, f_w) = measure("wide", 10.0);
    println!();

    // Precision edge over bf16 holds where all three cover the range (wide band: bf16 finite).
    assert!(
        g_w < f_w,
        "GF-T16 should beat bf16 on RMSNorm (wide): {g_w} !< {f_w}"
    );

    // In-range (narrow) GF-T16 and binary16 are task-level peers -- no overclaim either way.
    assert!(
        g_n < 2.0 * b_n && b_n < 2.0 * g_n,
        "in-range RMSNorm GF-T16/binary16 should be peers (within 2x): {g_n} vs {b_n}"
    );

    // Range: squaring pushes the wide band past binary16's 2^15.99 ceiling, so its rms overflows
    // while GF-T16 (2^+/-40) holds. The mirror of the softmax loss -- here range is decisive.
    assert!(
        g_w < b_w,
        "GF-T16 should beat binary16 on the wide RMSNorm (range-bound): {g_w} !< {b_w}"
    );
    assert!(
        b_w.is_infinite() || b_w > 10.0 * g_w,
        "wide binary16 RMSNorm error should be catastrophic vs GF-T16"
    );
}
