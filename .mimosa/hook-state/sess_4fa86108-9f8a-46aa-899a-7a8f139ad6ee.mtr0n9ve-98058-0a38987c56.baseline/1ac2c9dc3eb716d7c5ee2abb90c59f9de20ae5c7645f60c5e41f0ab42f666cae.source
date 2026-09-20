//! gft_ladder_cures_tiny_weights -- the follow-up to gft4_vs_bitnet's honest limit. GF-T4 LOST
//! to BitNet-1.58 on tiny weights because its 2^+/-4 range floors anything below 2^-4. The ladder
//! ANSWERS that: a wider rung reaches the small weights. GF-T8 (range 2^+/-13, 4 mantissa bits) and
//! GF-T16 (2^+/-40, 9 mantissa bits) both represent the same tiny-weight tensor and beat BitNet's
//! three levels -- the weakness is a bottom-rung range limit, not a ternary-format limit. "Pick the
//! right rung" is the fix, and here it is, measured.

fn bitnet_quantize(w: &[f64]) -> Vec<f64> {
    let scale = w.iter().map(|x| x.abs()).sum::<f64>() / w.len().max(1) as f64;
    if scale == 0.0 {
        return vec![0.0; w.len()];
    }
    w.iter()
        .map(|&x| (x / scale).round().clamp(-1.0, 1.0) * scale)
        .collect()
}

/// GF-T rung quantize: `mant_bits` mantissa bits, exponent clamped to [-bias, bias]. Below 2^-bias
/// the value floors up to 2^-bias (the range limit that bit GF-T4 -- but a higher rung's bias is far lower).
fn gft_quantize_one(x: f64, mant_bits: u32, bias: i32) -> f64 {
    if x == 0.0 {
        return 0.0;
    }
    let s = x.signum();
    let a = x.abs();
    let e = a.log2().floor().clamp(-(bias as f64), bias as f64);
    let scale = 2f64.powf(e);
    let m = (a / scale).clamp(1.0, 2.0);
    let levels = 2f64.powi(mant_bits as i32);
    let mq = (m * levels).round() / levels;
    s * mq * scale
}
fn gft_quantize(w: &[f64], mant_bits: u32, bias: i32) -> Vec<f64> {
    w.iter()
        .map(|&x| gft_quantize_one(x, mant_bits, bias))
        .collect()
}

fn dot(w: &[f64], x: &[f64]) -> f64 {
    w.iter().zip(x).map(|(&a, &b)| a * b).sum()
}
fn rel(approx: f64, exact: f64) -> f64 {
    ((approx - exact) / exact).abs()
}

fn neuron(n: usize, w_lo: f64, w_hi: f64, seed: u64) -> (Vec<f64>, Vec<f64>) {
    let mut s = seed;
    let mut next = || {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (s >> 33) as f64 / (1u64 << 31) as f64
    };
    let w: Vec<f64> = (0..n)
        .map(|_| {
            let sign = if next() < 0.5 { -1.0 } else { 1.0 };
            sign * (w_lo + next() * (w_hi - w_lo))
        })
        .collect();
    let x: Vec<f64> = (0..n).map(|_| 0.25 + next() * 1.75).collect();
    (w, x)
}

// rung geometry: (mant_bits, bias)
const GFT4: (u32, i32) = (1, 4);
const GFT8: (u32, i32) = (4, 13);
const GFT16: (u32, i32) = (9, 40);

#[test]
fn a_wider_rung_beats_bitnet_on_the_same_tiny_weights_gft4_lost() {
    // The SAME tiny-weight tensor from gft4_vs_bitnet (all magnitudes in [2^-11, ~2^-5.6]).
    let (w, x) = neuron(256, 0.0005, 0.02, 0xC0FF_EE11);
    let exact = dot(&w, &x);
    let e_bitnet = rel(dot(&bitnet_quantize(&w), &x), exact);
    let e_gft4 = rel(dot(&gft_quantize(&w, GFT4.0, GFT4.1), &x), exact);
    let e_gft8 = rel(dot(&gft_quantize(&w, GFT8.0, GFT8.1), &x), exact);
    let e_gft16 = rel(dot(&gft_quantize(&w, GFT16.0, GFT16.1), &x), exact);

    // GF-T4 still loses (its 2^-4 floor) -- the baseline from gft4_vs_bitnet.
    assert!(
        e_gft4 > e_bitnet,
        "GF-T4 still loses on tiny weights (2^-4 floor): {e_gft4} > {e_bitnet}"
    );
    // But a wider rung reaches the small weights and beats BitNet.
    assert!(
        e_gft8 < e_bitnet,
        "GF-T8 (2^+/-13) beats BitNet on the tiny tensor: {e_gft8} !< {e_bitnet}"
    );
    assert!(
        e_gft16 < e_bitnet,
        "GF-T16 (2^+/-40) beats BitNet too: {e_gft16} !< {e_bitnet}"
    );
    // And the ladder still orders: GF-T16 (9 mant bits) at least as accurate as GF-T8 (4).
    assert!(
        e_gft16 <= e_gft8,
        "more mantissa still helps once the range is adequate"
    );
}

#[test]
fn the_range_floor_is_what_moves_between_rungs() {
    // The cure is RANGE, not mantissa: a value 0.001 (below GF-T4's 2^-4 = 0.0625) is floored by
    // GF-T4 but represented by GF-T8/16 (whose exponent reaches far below).
    let tiny = 0.001f64;
    assert!(
        gft_quantize_one(tiny, GFT4.0, GFT4.1) >= 2f64.powi(-4),
        "GF-T4 floors 0.001 up to 2^-4"
    );
    let q8 = gft_quantize_one(tiny, GFT8.0, GFT8.1);
    let q16 = gft_quantize_one(tiny, GFT16.0, GFT16.1);
    assert!(
        (q8 - tiny).abs() / tiny < 0.2,
        "GF-T8 represents 0.001 within its grid"
    );
    assert!(
        (q16 - tiny).abs() / tiny < 0.02,
        "GF-T16 represents 0.001 finely"
    );
}
