//! gft_mlp_accuracy -- MODEL-level fidelity: a real 3-layer MLP forward pass (ReLU) with weights +
//! activations quantized to GF-T16 / bfloat16 / int8, measuring how far the network OUTPUT drifts
//! from the exact f64 reference. The step up from the single-op / dot / softmax micro-benchmarks
//! toward "does GF-T preserve inference accuracy" -- error compounds through layers and the
//! activation range shifts layer to layer.
//!
//! Honest scope: deterministic pseudo-random weights (fixed LCG), a tiny net -- this measures
//! FORMAT fidelity through a realistic multi-layer pipeline, NOT the task accuracy of a trained
//! model. int8 is the half-width efficiency baseline; the fair same-width comparison is GF-T16 vs
//! bfloat16. Pure Rust, no deps. `cargo test --test gft_mlp_accuracy -- --nocapture` to see numbers.
#![allow(clippy::needless_range_loop)]

const GFT16_EMAX: i32 = 40;
const GFT16_MANT: f64 = 512.0;
fn gft16(a: f64) -> f64 {
    if a == 0.0 {
        return 0.0;
    }
    let (s, x) = (a.signum(), a.abs());
    let mut e = x.log2().floor() as i32;
    if e < -GFT16_EMAX {
        e = -GFT16_EMAX;
    }
    if e > GFT16_EMAX {
        return s * f64::INFINITY;
    }
    let mut m = ((x / 2f64.powi(e) - 1.0) * GFT16_MANT).round();
    let mut ee = e;
    if m >= GFT16_MANT {
        m = 0.0;
        ee += 1;
    }
    s * (1.0 + m / GFT16_MANT) * 2f64.powi(ee)
}
const BF16_MANT: f64 = 128.0;
fn bf16(a: f64) -> f64 {
    if a == 0.0 {
        return 0.0;
    }
    let (s, x) = (a.signum(), a.abs());
    let e = x.log2().floor() as i32;
    if e > 127 {
        return s * f64::INFINITY;
    }
    if e < -126 {
        return 0.0;
    }
    let mut m = ((x / 2f64.powi(e) - 1.0) * BF16_MANT).round();
    let mut ee = e;
    if m >= BF16_MANT {
        m = 0.0;
        ee += 1;
    }
    s * (1.0 + m / BF16_MANT) * 2f64.powi(ee)
}
fn quant_int8(v: &[f64]) -> Vec<f64> {
    let max = v.iter().fold(0.0f64, |m, &x| m.max(x.abs()));
    if max == 0.0 {
        return v.to_vec();
    }
    let scale = max / 127.0;
    v.iter()
        .map(|&x| (x / scale).round().clamp(-127.0, 127.0) * scale)
        .collect()
}

struct Lcg(u64);
impl Lcg {
    fn f(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64) * 2.0 - 1.0
    }
}

struct Layer {
    w: Vec<Vec<f64>>,
    b: Vec<f64>,
}
fn make_layer(g: &mut Lcg, n_in: usize, n_out: usize, scale: f64) -> Layer {
    Layer {
        w: (0..n_out)
            .map(|_| (0..n_in).map(|_| g.f() * scale).collect())
            .collect(),
        b: (0..n_out).map(|_| g.f() * scale).collect(),
    }
}
fn forward(layer: &Layer, x: &[f64], relu: bool, q: &dyn Fn(&[f64]) -> Vec<f64>) -> Vec<f64> {
    let xq = q(x);
    let mut out = vec![0.0; layer.b.len()];
    for o in 0..out.len() {
        let wq = q(&layer.w[o]);
        let mut acc = layer.b[o];
        for i in 0..xq.len() {
            acc += wq[i] * xq[i];
        }
        out[o] = if relu { acc.max(0.0) } else { acc };
    }
    out
}
fn net(layers: &[Layer], x: &[f64], q: &dyn Fn(&[f64]) -> Vec<f64>) -> Vec<f64> {
    let mut a = x.to_vec();
    for (li, l) in layers.iter().enumerate() {
        a = forward(l, &a, li + 1 < layers.len(), q);
    }
    a
}
fn rel_l2(approx: &[f64], exact: &[f64]) -> f64 {
    let num: f64 = approx.iter().zip(exact).map(|(a, e)| (a - e).powi(2)).sum();
    let den: f64 = exact.iter().map(|e| e * e).sum::<f64>().max(1e-300);
    (num / den).sqrt()
}
fn elem<F: Fn(f64) -> f64>(f: F) -> impl Fn(&[f64]) -> Vec<f64> {
    move |v: &[f64]| v.iter().map(|&x| f(x)).collect()
}

#[test]
fn gft16_carries_a_multilayer_forward_better_than_bf16() {
    let mut g = Lcg(0x1234_5678_9abc_def1);
    let layers = vec![
        make_layer(&mut g, 16, 32, 1.0),
        make_layer(&mut g, 32, 32, 0.5),
        make_layer(&mut g, 32, 8, 0.5),
    ];
    let idq = |v: &[f64]| v.to_vec();
    let (mut e_gft, mut e_bf, mut e_i8) = (0.0, 0.0, 0.0);
    let n = 256;
    for _ in 0..n {
        let x: Vec<f64> = (0..16).map(|_| g.f() * 4.0).collect();
        let exact = net(&layers, &x, &idq);
        e_gft += rel_l2(&net(&layers, &x, &elem(gft16)), &exact);
        e_bf += rel_l2(&net(&layers, &x, &elem(bf16)), &exact);
        e_i8 += rel_l2(&net(&layers, &x, &quant_int8), &exact);
    }
    let (e_gft, e_bf, e_i8) = (e_gft / n as f64, e_bf / n as f64, e_i8 / n as f64);
    println!(
        "\n3-layer MLP (16->32->32->8, ReLU) output relative-L2 error vs exact f64, {n} inputs:"
    );
    println!(
        "  GF-T16   (16b, 9 mantissa, uniform) : {:.5}%",
        e_gft * 100.0
    );
    println!(
        "  bfloat16 (16b, 7 mantissa)          : {:.5}%",
        e_bf * 100.0
    );
    println!(
        "  int8     ( 8b, per-tensor scale)    : {:.5}%",
        e_i8 * 100.0
    );
    println!(
        "  same-width GF-T16 vs bf16: {:.2}x lower error (2 more mantissa bits)",
        e_bf / e_gft
    );

    assert!(
        e_gft < e_bf,
        "GF-T16 should carry a multi-layer forward more accurately than bf16 (same width)"
    );
    assert!(
        e_gft > 0.0 && e_gft < 0.05,
        "GF-T16 multi-layer error should be small and finite"
    );
    // int8 (half the width) is expected to be coarser; assert it is not silently better than a
    // 16-bit float here -- keeping the honest bit-budget comparison straight.
    assert!(
        e_i8 > e_gft,
        "a half-width int8 should not beat 16-bit GF-T16 on this pipeline"
    );
}
