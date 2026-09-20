//! # `gf16` — GF16 host DSP model of the OFDM FFT / equalizer datapath (`-sim`)
//!
//! Bit-exact **host reference** for the φ-derived 16-bit float (**GF16**) that a
//! future `t27`-emitted Verilog OFDM demodulator will use inside the Mini's
//! **Zynq-7020 PL (~85K LC / ~220 DSP48)**. This lets M2's demod be prototyped
//! and conformance-checked in pure Rust *before any RTL or silicon exists*.
//!
//! ## What this is (and is not)
//! - It **is** a deterministic software model whose accumulation order maps 1:1
//!   onto a systolic MAC / radix-2 butterfly network, cross-checked against
//!   machine-generated vectors ([`tests/gf16_conformance.rs`]).
//! - It is **not** an accuracy claim. GF16's win over fp32 is **width / area**
//!   (16-bit vs 32-bit multiplier → more parallel taps per DSP48), **not**
//!   precision. The GoldenFloat paper (arXiv:2606.05017) makes *no* per-rung
//!   accuracy or superiority claim, so this model is validated against external
//!   reference vectors, never asserted "better".
//!
//! ## Status marker
//! `-sim` (host model). It graduates to `hw` only when the equivalent
//! `t27`-emitted Verilog is validated on real Zynq / Artix-7 silicon — out of
//! scope for this module. (GF16 itself is silicon-proven at 323 MHz on XC7A35T,
//! 35/35 codec testbench; that is the *format*, not this OFDM datapath.)
//!
//! ## Format (arXiv:2606.05017)
//! `[s:1][e:6][m:9]`, exponent **bias 31**, **round-to-nearest-even**, **no
//! subnormals**. Normalized value = `(-1)^s · 2^(e-31) · (1 + m/512)`.
//! `e == 0` → signed zero; `e == 63` → Inf (`m==0`) / NaN (`m!=0`).
//!
//! ## Arithmetic model
//! Every op is computed in `f64` ("infinite precision" accumulator) and rounded
//! **once** to GF16 on encode — exactly a hardware RNE quantizer. [`Gf16::fma`]
//! fuses `a*b + c` with a single rounding (`f64::mul_add`). The pure-Rust path
//! is the default; an optional off-by-default `goldenfloat-ffi` feature swaps
//! the scalar backend for the C ABI while keeping `#![forbid(unsafe_code)]` for
//! this crate (the `unsafe` FFI is isolated behind a safe adapter).
//!
//! Anchor: φ² + φ⁻² = 3.

use core::cmp::Ordering;

const M_BITS: u32 = 9;
const E_BITS: u32 = 6;
const BIAS: i32 = 31;
const M_MAX: u16 = (1 << M_BITS) - 1; // 511
const E_MAX: u16 = (1 << E_BITS) - 1; // 63
const MANT_SCALE: f64 = (1u32 << M_BITS) as f64; // 512.0
const EMIN: i32 = 1 - BIAS; // -30
const EMAX: i32 = (E_MAX as i32 - 1) - BIAS; // 31

/// Largest finite magnitude: `2^31 · (1 + 511/512)`.
#[inline]
fn gf16_max() -> f64 {
    (2.0f64).powi(EMAX) * (1.0 + f64::from(M_MAX) / MANT_SCALE)
}
/// Smallest positive normal: `2^-30`.
#[inline]
fn gf16_min_normal() -> f64 {
    (2.0f64).powi(EMIN)
}

/// A GF16 scalar (`[s:1][e:6][m:9]`, bias 31, RNE, no subnormals).
///
/// Stored as the raw 16-bit pattern; construct via [`Gf16::from_f32`] /
/// [`Gf16::from_bits`] and read via [`Gf16::to_f32`] / [`Gf16::bits`].
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Gf16(u16);

// `add`/`sub`/`mul` are named to mirror the C-ABI FFI symbols
// (`gf16_add`/`gf16_sub`/`gf16_mul`) defined in issue #8, and to keep the
// single-GF16-rounding semantics explicit at every call site. Implementing the
// `std::ops` traits instead would hide the rounding behind operators, so the
// named-method form is intentional here.
#[allow(clippy::should_implement_trait)]
impl Gf16 {
    /// Positive zero.
    pub const ZERO: Gf16 = Gf16(0);

    /// Wrap a raw 16-bit GF16 pattern.
    #[inline]
    pub const fn from_bits(bits: u16) -> Self {
        Gf16(bits)
    }

    /// Raw 16-bit pattern.
    #[inline]
    pub const fn bits(self) -> u16 {
        self.0
    }

    /// Round an `f32` to the nearest GF16 value (RNE, no subnormals).
    #[inline]
    pub fn from_f32(x: f32) -> Self {
        Gf16(encode(f64::from(x)))
    }

    /// Round an `f64` to the nearest GF16 value (RNE, no subnormals).
    #[inline]
    pub fn from_f64(x: f64) -> Self {
        Gf16(encode(x))
    }

    /// Decode to `f32`.
    #[inline]
    pub fn to_f32(self) -> f32 {
        decode(self.0) as f32
    }

    /// Decode to `f64` (exact).
    #[inline]
    pub fn to_f64(self) -> f64 {
        decode(self.0)
    }

    /// `round(self + rhs)` — single GF16 rounding.
    #[inline]
    pub fn add(self, rhs: Gf16) -> Gf16 {
        Gf16(encode(decode(self.0) + decode(rhs.0)))
    }

    /// `round(self - rhs)` — single GF16 rounding.
    #[inline]
    pub fn sub(self, rhs: Gf16) -> Gf16 {
        Gf16(encode(decode(self.0) - decode(rhs.0)))
    }

    /// `round(self * rhs)` — single GF16 rounding.
    #[inline]
    pub fn mul(self, rhs: Gf16) -> Gf16 {
        Gf16(encode(decode(self.0) * decode(rhs.0)))
    }

    /// Fused multiply-add `round(self*b + c)` — **one** rounding (one MAC cell).
    #[inline]
    pub fn fma(self, b: Gf16, c: Gf16) -> Gf16 {
        Gf16(encode(decode(self.0).mul_add(decode(b.0), decode(c.0))))
    }

    /// `true` if the pattern encodes NaN.
    #[inline]
    pub fn is_nan(self) -> bool {
        ((self.0 >> M_BITS) & E_MAX) == E_MAX && (self.0 & M_MAX) != 0
    }
}

/// Round an `f64` to a GF16 bit pattern (RNE, no subnormals).
///
/// Mirrors `scripts/gen_gf16_vectors.py::encode` bit-for-bit.
fn encode(x: f64) -> u16 {
    if x.is_nan() {
        return (E_MAX << M_BITS) | 1;
    }
    let sign: u16 = if x.is_sign_negative() { 1 } else { 0 };
    let ax = x.abs();
    // overflow guard (with a half-ulp tie margin) -> Inf
    if ax.is_infinite() || ax > gf16_max() * (1.0 + (2.0f64).powi(-(M_BITS as i32 + 1))) {
        return (sign << 15) | (E_MAX << M_BITS);
    }
    if ax == 0.0 {
        return sign << 15;
    }
    // ax = mant * 2^exp, with 1.0 <= mant < 2.0
    let (mant, exp) = frexp(ax);
    if exp < EMIN {
        // below smallest normal — no subnormals: round to 0 or min-normal (RNE)
        let min_normal = gf16_min_normal();
        return match ax.partial_cmp(&(min_normal * 0.5)) {
            Some(Ordering::Greater) => (sign << 15) | (1 << M_BITS),
            _ => sign << 15, // exactly half ties to even (mantissa 0) -> 0
        };
    }
    let frac = mant - 1.0; // [0, 1)
    let scaled = frac * MANT_SCALE; // [0, 512)
    let mut m = scaled as u32;
    let rem = scaled - f64::from(m);
    if rem > 0.5 || (rem == 0.5 && (m & 1) == 1) {
        m += 1;
    }
    let mut e = exp + BIAS;
    if m as f64 == MANT_SCALE {
        m = 0;
        e += 1;
    }
    if e >= E_MAX as i32 {
        return (sign << 15) | (E_MAX << M_BITS);
    }
    (sign << 15) | ((e as u16) << M_BITS) | (m as u16)
}

/// Decode a GF16 bit pattern to `f64` (exact).
///
/// Mirrors `scripts/gen_gf16_vectors.py::decode` bit-for-bit.
fn decode(bits: u16) -> f64 {
    let sign = if (bits >> 15) & 1 == 1 { -1.0 } else { 1.0 };
    let e = (bits >> M_BITS) & E_MAX;
    let m = bits & M_MAX;
    if e == 0 {
        return sign * 0.0;
    }
    if e == E_MAX {
        return sign * if m == 0 { f64::INFINITY } else { f64::NAN };
    }
    sign * (2.0f64).powi(i32::from(e) - BIAS) * (1.0 + f64::from(m) / MANT_SCALE)
}

/// `frexp`: return `(mant, exp)` with `x = mant * 2^exp`, `1.0 <= mant < 2.0`
/// for finite positive `x`. (Rust std has no `frexp`, so compute it directly.)
#[inline]
fn frexp(x: f64) -> (f64, i32) {
    // x is finite, positive, non-zero here.
    let exp = x.log2().floor() as i32;
    let mut mant = x / (2.0f64).powi(exp);
    // guard floating rounding at the octave boundary
    let mut e = exp;
    if mant >= 2.0 {
        mant /= 2.0;
        e += 1;
    } else if mant < 1.0 {
        mant *= 2.0;
        e -= 1;
    }
    (mant, e)
}

// ---------------------------------------------------------------------------
// phi_dot / phi_fma — OUR composed primitives (tap accumulation).
// ---------------------------------------------------------------------------

/// One MAC cell: `acc <- round(a*b + acc)`, a single GF16 rounding.
///
/// This is the composable primitive both scalar backends share; it does **not**
/// exist as a GF16 hardware op — it is built from [`Gf16::fma`].
#[inline]
pub fn phi_fma(a: Gf16, b: Gf16, acc: Gf16) -> Gf16 {
    a.fma(b, acc)
}

/// Sequential dot product over GF16: `acc = 0; for k { acc = phi_fma(a[k], b[k], acc) }`.
///
/// **Accumulation order is fixed left-to-right with one fused MAC per tap**, so
/// it maps deterministically onto a future `t27` systolic MAC chain. Inputs must
/// be equal length (extra elements of the longer slice are ignored, matching a
/// fixed-length hardware tap line).
pub fn phi_dot(a: &[Gf16], b: &[Gf16]) -> Gf16 {
    let mut acc = Gf16::ZERO;
    for (ak, bk) in a.iter().zip(b.iter()) {
        acc = phi_fma(*ak, *bk, acc);
    }
    acc
}

// ---------------------------------------------------------------------------
// Complex GF16 + radix-2 DIT FFT + 1-tap equalizer (OFDM datapath).
// Expressed only via Gf16 ops so it maps 1:1 onto the RTL butterfly network.
// ---------------------------------------------------------------------------

/// A complex value with GF16 real/imag parts.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
pub struct CGf16 {
    /// Real part.
    pub re: Gf16,
    /// Imaginary part.
    pub im: Gf16,
}

impl CGf16 {
    /// Construct from raw GF16 parts.
    #[inline]
    pub const fn new(re: Gf16, im: Gf16) -> Self {
        CGf16 { re, im }
    }
    /// Construct by rounding two `f32`s.
    #[inline]
    pub fn from_f32(re: f32, im: f32) -> Self {
        CGf16 {
            re: Gf16::from_f32(re),
            im: Gf16::from_f32(im),
        }
    }
    #[inline]
    fn add(self, o: CGf16) -> CGf16 {
        CGf16::new(self.re.add(o.re), self.im.add(o.im))
    }
    #[inline]
    fn sub(self, o: CGf16) -> CGf16 {
        CGf16::new(self.re.sub(o.re), self.im.sub(o.im))
    }
    /// Complex multiply; each real op rounded once (matches the RTL 4-mul form).
    #[inline]
    fn mul(self, o: CGf16) -> CGf16 {
        let (xr, xi, yr, yi) = (
            self.re.to_f64(),
            self.im.to_f64(),
            o.re.to_f64(),
            o.im.to_f64(),
        );
        CGf16::new(
            Gf16::from_f64(xr * yr - xi * yi),
            Gf16::from_f64(xr * yi + xi * yr),
        )
    }
}

/// Bit-reversal permutation of a slice (used for iterative DIT FFT).
fn bit_reverse(x: &[CGf16]) -> Vec<CGf16> {
    let n = x.len();
    let bits = n.trailing_zeros();
    let mut out = vec![CGf16::default(); n];
    for (i, &v) in x.iter().enumerate() {
        let r = (i as u32).reverse_bits() >> (32 - bits);
        out[r as usize] = v;
    }
    out
}

/// Radix-2 decimation-in-time FFT over GF16 (`N` must be a power of two).
///
/// Twiddles `W_len^k = exp(-2πi·k/len)` are GF16-quantized. The stage schedule
/// (bit-reversed input, `len = 2..N`) is the canonical DIT order and is fixed,
/// so it maps deterministically onto the future butterfly network.
pub fn fft(x: &[CGf16]) -> Vec<CGf16> {
    let n = x.len();
    assert!(n.is_power_of_two(), "FFT length must be a power of two");
    let mut a = bit_reverse(x);
    let mut len = 2usize;
    while len <= n {
        let half = len / 2;
        let mut start = 0usize;
        while start < n {
            for k in 0..half {
                let ang = -2.0 * core::f64::consts::PI * (k as f64) / (len as f64);
                let w = CGf16::new(Gf16::from_f64(ang.cos()), Gf16::from_f64(ang.sin()));
                let u = a[start + k];
                let t = w.mul(a[start + k + half]);
                a[start + k] = u.add(t);
                a[start + k + half] = u.sub(t);
            }
            start += len;
        }
        len <<= 1;
    }
    a
}

/// Per-subcarrier 1-tap zero-forcing equalizer: `xhat[k] = y[k] · h_inv[k]`.
pub fn equalize(y: &[CGf16], h_inv: &[CGf16]) -> Vec<CGf16> {
    y.iter()
        .zip(h_inv.iter())
        .map(|(&yk, &hk)| yk.mul(hk))
        .collect()
}

// ---------------------------------------------------------------------------
// Area metric: GF16 real-multiplier width vs fp32 baseline (report, no claim).
// ---------------------------------------------------------------------------

/// Multiplier-width comparison for the N-point complex FFT/equalizer datapath.
///
/// Returns `(gf16_mult_bits, fp32_mult_bits, taps_per_dsp48_ratio)`. This is a
/// *width/area* argument (the honest GF16 win), **not** an accuracy claim.
///
/// A Xilinx DSP48 hosts one 18×~25 multiplier. A GF16 significand multiply is
/// 10×10 (`1+9` mantissa bits), so it fits a single DSP48 with room to spare and
/// two can share/pack where an fp32 24×24 significand multiply needs a full
/// DSP48 (often two for the full 24-bit width). The reported ratio is the
/// conservative significand-width ratio `24/10`.
pub fn multiplier_width_report(n: usize) -> (u32, u32, f64) {
    let gf16_signif = M_BITS + 1; // 10
    let fp32_signif = 24u32; // fp32 has a 23-bit stored mantissa + hidden bit
    let ratio = f64::from(fp32_signif) / f64::from(gf16_signif);
    // n only scales both datapaths equally; kept for call-site clarity.
    let _ = n;
    (gf16_signif, fp32_signif, ratio)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gf16_scalar_roundtrip() {
        // decode∘encode must be idempotent, and simple exact values exact.
        for &f in &[0.0f32, 1.0, -1.0, 0.5, 2.0, 3.0, 8.0, -0.25] {
            let g = Gf16::from_f32(f);
            assert_eq!(g.to_f32(), f, "exact value {f} not represented exactly");
            // idempotent quantization
            let g2 = Gf16::from_f32(g.to_f32());
            assert_eq!(g.bits(), g2.bits(), "quantizer not idempotent for {f}");
        }
        // 1.618… (φ) is inexact but must round-trip through bits idempotently.
        let phi = Gf16::from_f32(1.618_034);
        assert_eq!(phi.bits(), Gf16::from_f32(phi.to_f32()).bits());
    }

    #[test]
    fn phi_identity_anchor() {
        // φ² + φ⁻² = 3 sanity within GF16 rounding (documents the anchor).
        let phi = 1.618_033_988_75_f64;
        let a = Gf16::from_f64(phi * phi);
        let b = Gf16::from_f64((1.0 / phi) * (1.0 / phi));
        let s = a.add(b).to_f64();
        assert!((s - 3.0).abs() < 0.05, "phi anchor drifted: {s}");
    }

    #[test]
    fn fma_single_rounding() {
        // fma(a,b,c) fuses; must equal one-shot round of a*b+c.
        let a = Gf16::from_f32(1.3);
        let b = Gf16::from_f32(2.7);
        let c = Gf16::from_f32(0.9);
        let fused = a.fma(b, c);
        let expect = Gf16::from_f64(a.to_f64().mul_add(b.to_f64(), c.to_f64()));
        assert_eq!(fused.bits(), expect.bits());
    }

    #[test]
    fn width_report_is_area_not_accuracy() {
        let (gf, fp, ratio) = multiplier_width_report(64);
        assert_eq!(gf, 10);
        assert_eq!(fp, 24);
        assert!(ratio >= 2.0, "expected >=2x taps-per-DSP48 width argument");
    }
}
