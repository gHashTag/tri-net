//! gft_sparsity_no_zero -- the HONEST structural fact behind gft4_vs_bitnet: GF-T has no
//! in-format ZERO. Its value is (1 + M/2^M) * 2^(offset - bias), always >= 2^-bias (offset 0,
//! M 0 gives 2^-bias, not 0); the reserved special row is the inf/nan analogue, not zero. So
//! BitNet's real edge on a SPARSE tensor is its EXACT ZERO among {-1,0,1}, which GF-T lacks --
//! a dense GF-T encoding must floor an exact-zero weight up to 2^-bias.
//!
//! BUT the bite is a LOW-RUNG artifact: 2^-bias is 2^-4 = 0.0625 at GF-T4 (significant) yet
//! 2^-40 ~ 1e-12 at GF-T16 (negligible -- effectively zero). So the higher rung's astronomically
//! small floor makes the missing zero irrelevant, exactly as a wider rung cured the tiny-weight
//! loss (gft_ladder_cures_tiny_weights). The honest sidestep in real use is a sparsity mask.

/// FAITHFUL GF-T quantize: there is NO zero, so an exact-zero input floors up to the smallest
/// magnitude 2^-bias (dense encoding, no sparsity mask). Non-zero values quantize normally.
fn gft_quantize_no_zero(x: f64, mant_bits: u32, bias: i32) -> f64 {
    if x == 0.0 {
        return 2f64.powi(-bias); // GF-T cannot encode 0 -> smallest positive magnitude
    }
    let s = x.signum();
    let a = x.abs();
    let e = a.log2().floor().clamp(-(bias as f64), bias as f64);
    let scale = 2f64.powf(e);
    let m = (a / scale).clamp(1.0, 2.0);
    let levels = 2f64.powi(mant_bits as i32);
    s * ((m * levels).round() / levels) * scale
}

fn dot(w: &[f64], x: &[f64]) -> f64 {
    w.iter().zip(x).map(|(&a, &b)| a * b).sum()
}
fn rel(approx: f64, exact: f64) -> f64 {
    ((approx - exact) / exact).abs()
}

/// A 50%-sparse neuron: half the weights are EXACTLY zero, the rest are mid-range (LCG).
fn sparse_neuron(n: usize, seed: u64) -> (Vec<f64>, Vec<f64>) {
    let mut s = seed;
    let mut next = || {
        s = s
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (s >> 33) as f64 / (1u64 << 31) as f64
    };
    let w: Vec<f64> = (0..n)
        .map(|_| {
            if next() < 0.5 {
                0.0 // exact zero
            } else {
                let sign = if next() < 0.5 { -1.0 } else { 1.0 };
                sign * (0.5 + next() * 1.5) // [0.5, 2)
            }
        })
        .collect();
    let x: Vec<f64> = (0..n).map(|_| 0.25 + next() * 1.75).collect();
    (w, x)
}

const GFT4: (u32, i32) = (1, 4);
const GFT16: (u32, i32) = (9, 40);

#[test]
fn gf_t_has_no_in_format_zero() {
    // The smallest representable magnitude is 2^-bias > 0 at every rung; no encoding yields 0.
    for &(_, bias) in &[GFT4, GFT16] {
        let min_mag = 2f64.powi(-bias);
        assert!(
            min_mag > 0.0,
            "GF-T's smallest magnitude 2^-{bias} is strictly positive (no zero)"
        );
        // an exact-zero input cannot map to 0 -- it floors up to the smallest magnitude.
        assert_eq!(
            gft_quantize_no_zero(0.0, 1, bias),
            min_mag,
            "0 floors up to 2^-{bias}"
        );
    }
}

#[test]
fn the_missing_zero_hurts_gft4_but_vanishes_by_gft16() {
    // On a 50%-sparse tensor, the honest, ROBUST statement is within-ladder: the no-zero floor's
    // error shrinks as the rung's bias grows. GF-T4 floors each zero to 2^-4 (significant); GF-T16
    // floors to 2^-40 (~1e-12, effectively zero) AND resolves the nonzeros finer -> far lower error.
    //
    // (Note on BitNet: whether the missing zero costs GF-T *against BitNet* is REGIME-dependent, not
    // absolute -- with mid-range nonzeros BitNet's own ternary coarseness dominates and GF-T4 can
    // still win despite the floor; the no-zero limit only decides the contest in the tiny-weight
    // regime of gft4_vs_bitnet. So the honest, rung-monotone claim is the within-ladder one below.)
    let (w, x) = sparse_neuron(256, 0x5A5A_0F0F);
    let exact = dot(&w, &x);

    let g4: Vec<f64> = w
        .iter()
        .map(|&v| gft_quantize_no_zero(v, GFT4.0, GFT4.1))
        .collect();
    let g16: Vec<f64> = w
        .iter()
        .map(|&v| gft_quantize_no_zero(v, GFT16.0, GFT16.1))
        .collect();
    let e_g4 = rel(dot(&g4, &x), exact);
    let e_g16 = rel(dot(&g16, &x), exact);

    assert!(
        e_g16 < e_g4,
        "the higher rung's 2^-40 floor makes the no-zero limit vanish: {e_g16} !< {e_g4}"
    );
    // The zero-floor error at GF-T16 is astronomically small: 2^-40 vs GF-T4's 2^-4.
    assert!(
        2f64.powi(-GFT16.1) < 2f64.powi(-GFT4.1) * 1e-9,
        "GF-T16's floor is >1e9x smaller than GF-T4's"
    );
}
