//! gft4_vs_bitnet -- GF-T4, the ternary-native BOTTOM rung, against BitNet-1.58, the ternary
//! WEIGHT quantizer it is most often compared to. The HONEST scorecard: neither strictly
//! dominates -- they win in different regimes, and the point is to say where.
//!
//! BitNet-1.58 rounds each weight to {-1,0,1} with a per-tensor absmean scale (~log2(3) = 1.58
//! bits/weight; activations kept high precision). Its three levels INCLUDE an exact zero.
//! GF-T4 is a 4-bit tapered float: sign + 2 balanced-ternary exponent trits + 1 mantissa bit,
//! i.e. {+/-1.0, +/-1.5} * 2^e over e in [-4,4] -- ~36 magnitudes, finer than three levels, but
//! with NO sub-2^-4 region (its smallest magnitude is 2^-4; there is no denormal tail).
//!
//! So: on MID-RANGE weights GF-T4's finer grid wins; on a TINY-WEIGHT / sparse tensor BitNet's
//! exact zero wins because GF-T4 floors small weights up to 2^-4. This test pins both regimes,
//! plus the footprint trade (4 vs 1.58 bits). Overclaiming either direction would be the bug.

fn bitnet_quantize(w: &[f64]) -> Vec<f64> {
    let scale = w.iter().map(|x| x.abs()).sum::<f64>() / w.len().max(1) as f64;
    if scale == 0.0 {
        return vec![0.0; w.len()];
    }
    w.iter()
        .map(|&x| (x / scale).round().clamp(-1.0, 1.0) * scale) // scale * {-1,0,1}
        .collect()
}

/// GF-T4 grid {+/-1.0, +/-1.5} * 2^e, 1 mantissa bit, exponent clamped to [-4, 4] (offset_max 8).
/// A magnitude below 2^-4 has no representation but zero -> it floors up to 2^-4 (the honest limit).
fn gft4_quantize_one(x: f64) -> f64 {
    if x == 0.0 {
        return 0.0;
    }
    let s = x.signum();
    let a = x.abs();
    let e = a.log2().floor().clamp(-4.0, 4.0);
    let scale = 2f64.powf(e);
    let m = (a / scale).clamp(1.0, 2.0);
    let mq = (m * 2.0).round() / 2.0; // 1 mantissa bit -> {1.0, 1.5, 2.0}
    s * mq * scale
}
fn gft4_quantize(w: &[f64]) -> Vec<f64> {
    w.iter().map(|&x| gft4_quantize_one(x)).collect()
}

fn dot(w: &[f64], x: &[f64]) -> f64 {
    w.iter().zip(x).map(|(&a, &b)| a * b).sum()
}
fn rel(approx: f64, exact: f64) -> f64 {
    ((approx - exact) / exact).abs()
}

/// A neuron with weights drawn from a chosen magnitude band and positive activations (LCG).
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

#[test]
fn gft4_is_finer_on_mid_range_weights() {
    // Weights comfortably inside GF-T4's 2^+/-4 range -> its 36 magnitudes beat BitNet's 3 levels.
    let (w, x) = neuron(256, 0.125, 4.0, 0x1958_4BE7);
    let exact = dot(&w, &x);
    let e_gft4 = rel(dot(&gft4_quantize(&w), &x), exact);
    let e_bitnet = rel(dot(&bitnet_quantize(&w), &x), exact);
    assert!(
        e_gft4 < e_bitnet,
        "on mid-range weights GF-T4's finer grid wins: {e_gft4} !< {e_bitnet}"
    );
}

#[test]
fn bitnet_wins_on_tiny_weights_via_its_exact_zero() {
    // A tensor of tiny weights (well below 2^-4): BitNet zeros them (exact); GF-T4 has no
    // sub-2^-4 region, so it floors each up to 2^-4 and injects error. The honest limit of the
    // bottom rung -- a higher rung (wider range) would be the fix, not a claim GF-T4 always wins.
    let (w, x) = neuron(256, 0.0005, 0.02, 0xC0FF_EE11);
    let exact = dot(&w, &x);
    let e_gft4 = rel(dot(&gft4_quantize(&w), &x), exact);
    let e_bitnet = rel(dot(&bitnet_quantize(&w), &x), exact);
    assert!(
        e_bitnet < e_gft4,
        "on tiny weights BitNet's exact zero beats GF-T4's 2^-4 floor: {e_bitnet} !< {e_gft4}"
    );
}

#[test]
fn the_footprint_trade_is_explicit() {
    let gft4_bits = 4.0f64;
    let bitnet_bits = 3.0f64.log2(); // ~1.585
    assert!(
        bitnet_bits < gft4_bits,
        "BitNet is the smaller footprint (1.58 < 4 bits)"
    );
    assert!(
        (bitnet_bits - 1.585).abs() < 1e-3,
        "ternary is log2(3) ~ 1.585 bits/weight"
    );
    let gft4_levels = 2 * 2 * 9 + 1; // sign * mantissa * exponents(offset 0..8) + zero
    assert!(
        gft4_levels > 3,
        "GF-T4 has {gft4_levels} magnitudes vs BitNet's 3 -- finer, at more bits"
    );
}
