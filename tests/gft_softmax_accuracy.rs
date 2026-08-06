//! gft_softmax_accuracy -- TASK-LEVEL accuracy on the softmax weight vector (the attention atom).
//!
//! `gft_task_accuracy` covered a dot product (linear accumulation, all terms contribute). This
//! covers the OTHER shape at the heart of a transformer: softmax over logits, i.e. attention
//! weights. It is deliberately the workload where GF-T16's range advantage is LEAST obvious --
//! softmax normalizes mass toward the peak, so tiny tail weights (where binary16's 2^-24 floor
//! bites) carry almost no probability, while the TOP weights (near 1, where mantissa bits bite)
//! dominate the error. So this test is an honest BOUNDARY probe -- and the MEASURED verdict is a
//! clean negative for GF-T16 here: binary16 WINS softmax total-variation in both bands. In the
//! wide band binary16 even flushes 100/256 tail keys to zero, yet STILL wins -- proving the range
//! GF-T16 offers is wasted under mass concentration, while binary16's extra mantissa bit (10 vs 9)
//! pays off at the peak. GF-T16 stays ~3-4x ahead of bf16 (7 mantissa bits) throughout. Net map:
//! GF-T16 owns range-bound linear accumulation (gft_task_accuracy's wide dot product) but LOSES
//! precision-bound, mass-concentrated softmax to binary16. Honesty over a tidy win.
//!
//! Model: w_i = round_fmt(exp(l_i - max_l)); normalize Z = sum(w) and q_i = w_i/Z in f64; compare
//! to the exact f64 softmax p via total-variation distance TV = 0.5*sum|p_i - q_i|. Two logit
//! spreads (deterministic LCG). We also report how many keys each format flushed to zero.
//!
//! Pure Rust, no deps, no Python, no spec pipeline. Roundtrip models copied verbatim from
//! src/bin/gft16_vs_binary16.rs (same ruler). Run: `cargo test --test gft_softmax_accuracy -- --nocapture`.

// ---- Roundtrip models copied VERBATIM from src/bin/gft16_vs_binary16.rs. ----

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

// ---- Workload: logits from a deterministic LCG, spread over [0, spread] nats. ----

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

fn logits(n: usize, spread: f64, seed: u64) -> Vec<f64> {
    let mut g = Lcg(seed);
    (0..n).map(|_| spread * g.next01()).collect()
}

/// Format-modelled softmax: round each exp-weight through `round`, normalize in f64.
/// Returns (distribution, keys_flushed_to_zero).
fn softmax_fmt(logits: &[f64], round: fn(f64) -> f64) -> (Vec<f64>, usize) {
    let max = logits.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let w: Vec<f64> = logits.iter().map(|&l| round((l - max).exp())).collect();
    let lost = w.iter().filter(|&&x| x == 0.0).count();
    let z: f64 = w.iter().sum();
    (w.iter().map(|&x| x / z).collect(), lost)
}

fn softmax_exact(logits: &[f64]) -> Vec<f64> {
    let max = logits.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let w: Vec<f64> = logits.iter().map(|&l| (l - max).exp()).collect();
    let z: f64 = w.iter().sum();
    w.iter().map(|&x| x / z).collect()
}

/// Total-variation distance between two distributions.
fn tv(p: &[f64], q: &[f64]) -> f64 {
    0.5 * p.iter().zip(q).map(|(a, b)| (a - b).abs()).sum::<f64>()
}

/// Returns (tv_gft, tv_binary16, tv_bf16, binary16_keys_lost).
fn measure(band: &str, spread: f64) -> (f64, f64, f64, usize) {
    let l = logits(256, spread, 0x9E3779B97F4A7C15);
    let p = softmax_exact(&l);
    let (qg, lg) = softmax_fmt(&l, gft16_roundtrip);
    let (qb, lb) = softmax_fmt(&l, binary16_roundtrip);
    let (qf, lf) = softmax_fmt(&l, bf16_roundtrip);
    let (tg, tb, tf) = (tv(&p, &qg), tv(&p, &qb), tv(&p, &qf));
    println!(
        "  {:<7} spread {:>2.0} nats   TV: GF-T16 {:.3e} (lost {})   binary16 {:.3e} (lost {})   bf16 {:.3e} (lost {})",
        band, spread, tg, lg, tb, lb, tf, lf
    );
    (tg, tb, tf, lb)
}

#[test]
fn gft_softmax_task_accuracy() {
    println!("\nTASK-LEVEL softmax total-variation error vs exact f64 (256 attention logits):");
    let (g_n, b_n, f_n, _) = measure("narrow", 6.0);
    let (g_w, b_w, f_w, b_lost_w) = measure("wide", 30.0);
    println!();

    // LOCKED measured verdict -- this test documents a BOUNDARY of GF-T16, not a win.

    // 1) GF-T16 keeps its precision edge over bf16 (9 vs 7 mantissa bits) in both bands.
    assert!(
        g_n < f_n,
        "GF-T16 should beat bf16 on softmax (narrow): {g_n} !< {f_n}"
    );
    assert!(
        g_w < f_w,
        "GF-T16 should beat bf16 on softmax (wide): {g_w} !< {f_w}"
    );

    // 2) binary16 WINS softmax in both bands -- its 10th mantissa bit pays off at the peak where
    //    mass concentrates. We assert the loss so the suite refuses to let us pretend GF-T16 wins
    //    everywhere. (Measured: GF-T16 ~2-3x binary16's TV.)
    assert!(
        b_n < g_n,
        "binary16 is the more accurate softmax format (narrow): {b_n} !< {g_n}"
    );
    assert!(
        b_w < g_w,
        "binary16 is the more accurate softmax format (wide): {b_w} !< {g_w}"
    );

    // 3) Mechanism proof: in the wide band binary16 flushes a large chunk of tail keys to zero and
    //    STILL wins -- so the range GF-T16 spends bits on is worthless under mass concentration.
    assert!(
        b_lost_w >= 50,
        "binary16 should flush many tail keys in the wide band: lost {b_lost_w}"
    );
    assert!(
        b_w < g_w,
        "...yet binary16 still wins on TV, proving range is irrelevant for softmax"
    );
}
