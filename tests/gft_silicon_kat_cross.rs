//! gft_silicon_kat_cross -- close the spec -> silicon -> oracle loop for the rungs that lacked it.
//! gft_dot_oracle cross-checks GF-T16 and gft32_challenge cross-checks GF-T32 against their
//! iverilog KATs; GF-T4 (fpga/gft/gft_mul4_kat_tb.v) and GF-T64 (fpga/gft/gft_mul64_kat_tb.v)
//! had no Rust twin. This transcribes the gft_mul arithmetic (from fpga/gft/gft_mul.v /
//! gft_mul64.v -- the SAME tri_gft_arith spec) in BigUint and asserts the EXACT packed (offset,
//! mantissa) tuples the iverilog KATs returned. If the Rust model ever drifts from the silicon,
//! this fails -- a cross-instrument guard (the broken-ruler discipline: two independent rulers).

use num_bigint::BigUint;

/// gft_mul, transcribed verbatim from fpga/gft/gft_mul.v:
///   prod   = (mant_one + a) * (mant_one + b)
///   thresh = (2*mant_one) * mant_one           -- one-bit renorm boundary
///   carry  = prod >= thresh
///   sum    = a_off + b_off + carry
///   off    = sum<bias ? 0 : (sum-bias>=offset_max ? offset_max : sum-bias)
///   mant   = carry ? prod/(2*mant_one) - mant_one : prod/mant_one - mant_one
fn gft_mul(
    a_off: u32,
    a_mant: &BigUint,
    b_off: u32,
    b_mant: &BigUint,
    mant_one: &BigUint,
    bias: u32,
    offset_max: u32,
) -> (u32, BigUint) {
    let prod = (mant_one + a_mant) * (mant_one + b_mant);
    let thresh = (mant_one * 2u32) * mant_one;
    let carry: u32 = if prod >= thresh { 1 } else { 0 };
    let sum = a_off + b_off + carry;
    let off = if sum < bias {
        0
    } else {
        let r = sum - bias;
        if r >= offset_max {
            offset_max
        } else {
            r
        }
    };
    let mant = if carry == 1 {
        &prod / (mant_one * 2u32) - mant_one
    } else {
        &prod / mant_one - mant_one
    };
    (off, mant)
}

fn big(x: u64) -> BigUint {
    BigUint::from(x)
}
fn pow2(k: u32) -> BigUint {
    BigUint::from(1u32) << k as usize
}

#[test]
fn gft4_matches_the_iverilog_kat() {
    // GF-T4: mant_one 2, bias 4, offset_max 8. Exact tuples from fpga/gft/gft_mul4_kat_tb.v.
    let (m1, bias, omax) = (big(2), 4u32, 8u32);
    let mul = |ao, am: u64, bo, bm: u64| gft_mul(ao, &big(am), bo, &big(bm), &m1, bias, omax);
    assert_eq!(mul(4, 0, 4, 0), (4, big(0)), "1.0*1.0 -> (4,0)");
    assert_eq!(mul(4, 0, 4, 1), (4, big(1)), "1.0*1.5 -> (4,1)");
    assert_eq!(
        mul(4, 1, 4, 1),
        (5, big(0)),
        "1.5*1.5=2.25 -> 2.0 RTZ -> (5,0)"
    );
    assert_eq!(
        mul(5, 1, 5, 1),
        (7, big(0)),
        "3.0*3.0=9 -> 8.0 RTZ -> (7,0)"
    );
    assert_eq!(
        mul(7, 1, 7, 1),
        (8, big(0)),
        "(7,1)^2 -> exponent saturates -> (8,0)"
    );
}

#[test]
fn gft64_matches_the_iverilog_kat() {
    // GF-T64: mant_one 2^64, bias 9841, offset_max 19682. Tuples from fpga/gft/gft_mul64_kat_tb.v.
    let (m1, bias, omax) = (pow2(64), 9841u32, 19682u32);
    // 1.5 = (9841, 2^63); 1.5*1.5 = 2.25 -> (9842, 2^61).
    assert_eq!(
        gft_mul(9841, &pow2(63), 9841, &pow2(63), &m1, bias, omax),
        (9842, pow2(61)),
        "GF-T64 1.5^2 -> (9842, 2^61)"
    );
    // 1.25 = (9841, 2^62); 1.25*1.25 = 1.5625 = 1 + 9/16 -> no carry -> (9841, 9*2^60).
    assert_eq!(
        gft_mul(9841, &pow2(62), 9841, &pow2(62), &m1, bias, omax),
        (9841, big(9) * pow2(60)),
        "GF-T64 1.25^2 -> (9841, 9*2^60)"
    );
    // 1.0 = (9841, 0); 1.0*1.0 = 1.0 -> (9841, 0).
    assert_eq!(
        gft_mul(9841, &big(0), 9841, &big(0), &m1, bias, omax),
        (9841, big(0)),
        "GF-T64 1.0^2 -> (9841, 0)"
    );
}

#[test]
fn the_transcription_reproduces_gft16_and_gft32_too() {
    // Sanity that the SAME generic gft_mul reproduces the already-cross-checked rungs, so GF-T4/64
    // are validated by the identical code path -- not a bespoke model that could diverge.
    // GF-T16: mant_one 512, bias 40, offset_max 80. 1.5=(40,256); 1.5^2 -> (41,64) via (41,256)^2? use silicon KAT (41,256)^2=(43,64).
    let g16 = |ao, am: u64, bo, bm: u64| gft_mul(ao, &big(am), bo, &big(bm), &big(512), 40, 80);
    assert_eq!(
        g16(41, 256, 41, 256),
        (43, big(64)),
        "GF-T16 (41,256)^2 -> (43,64) [gft_dot_oracle]"
    );
    // GF-T32: mant_one 2^25, bias 364, offset_max 728. (364,2^24)^2 -> (365,2^22) [gft32_challenge].
    let g32 = |ao, am: u64, bo, bm: u64| gft_mul(ao, &big(am), bo, &big(bm), &pow2(25), 364, 728);
    assert_eq!(
        g32(364, 1 << 24, 364, 1 << 24),
        (365, pow2(22)),
        "GF-T32 1.5^2 -> (365,2^22)"
    );
}
