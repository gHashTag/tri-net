//! gft64_add_dot_kat_cross -- extends the cross-instrument guard (gft_silicon_kat_cross) from
//! the GF-T64 MULTIPLIER to its ADDER and MACs. gft_add64 / gft_dot2_64 / gft_dot4_64 have
//! iverilog KATs (fpga/gft/*_kat_tb.v) but no Rust twin. This transcribes gft_add (from
//! fpga/gft/gft_add.v) and composes it with gft_mul (gft_mul.v) into the same dot2/dot4 wiring
//! the silicon uses, then asserts the EXACT (offset, mantissa) tuples the iverilog KATs returned.
//! If the Rust model of the add/renorm or the MAC reduction ever drifts from the silicon, this
//! fails -- two independent rulers on the GF-T64 arithmetic beyond just multiply.

use num_bigint::BigUint;

fn big(x: u64) -> BigUint {
    BigUint::from(x)
}
fn pow2(k: u32) -> BigUint {
    BigUint::from(1u32) << k as usize
}

/// gft_mul, transcribed from fpga/gft/gft_mul.v (same as gft_silicon_kat_cross).
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

/// gft_add, transcribed from fpga/gft/gft_add.v: align the smaller significand by the offset
/// difference, add, renormalize one carry (saturating the exponent at offset_max).
fn gft_add(
    a_off: u32,
    a_mant: &BigUint,
    b_off: u32,
    b_mant: &BigUint,
    mant_one: &BigUint,
    offset_max: u32,
    sig_bits: u32,
) -> (u32, BigUint) {
    let a_hi = a_off >= b_off;
    let (hi_off, hi_m, lo_off, lo_m) = if a_hi {
        (a_off, a_mant, b_off, b_mant)
    } else {
        (b_off, b_mant, a_off, a_mant)
    };
    let d = hi_off - lo_off;
    let sb = if d >= sig_bits {
        big(0)
    } else {
        (mant_one + lo_m) >> d as usize
    };
    let sum = (mant_one + hi_m) + sb;
    let carry = sum >= (mant_one * 2u32);
    let out_off = if carry {
        let e = hi_off + 1;
        if e >= offset_max {
            offset_max
        } else {
            e
        }
    } else {
        hi_off
    };
    let out_mant = if carry {
        (&sum >> 1) - mant_one
    } else {
        &sum - mant_one
    };
    (out_off, out_mant)
}

// GF-T64 geometry.
fn m1() -> BigUint {
    pow2(64)
}
const BIAS: u32 = 9841;
const OMAX: u32 = 19682;
const SIG: u32 = 65;

fn mul64(ao: u32, am: &BigUint, bo: u32, bm: &BigUint) -> (u32, BigUint) {
    gft_mul(ao, am, bo, bm, &m1(), BIAS, OMAX)
}
fn add64(ao: u32, am: &BigUint, bo: u32, bm: &BigUint) -> (u32, BigUint) {
    gft_add(ao, am, bo, bm, &m1(), OMAX, SIG)
}

#[test]
fn gft_add64_matches_the_iverilog_kat() {
    // fpga/gft/gft_add64_kat_tb.v: 1.5+1.5 -> (9842, 2^63) ; 1.5+1.0 -> (9842, 2^62).
    assert_eq!(
        add64(9841, &pow2(63), 9841, &pow2(63)),
        (9842, pow2(63)),
        "1.5+1.5=3.0"
    );
    assert_eq!(
        add64(9841, &pow2(63), 9841, &big(0)),
        (9842, pow2(62)),
        "1.5+1.0=2.5"
    );
}

#[test]
fn gft_dot2_64_matches_the_iverilog_kat() {
    // dot2 = (a1*b1) + (a2*b2), composing mul64 + add64 exactly as gft_dot2_64.v.
    // both 1.5*1.5 -> (9843, 2^61) = 4.5 ; 1.5^2 + 1.0^2 -> (9842, 2^63 + 2^61) = 3.25.
    let p = mul64(9841, &pow2(63), 9841, &pow2(63)); // (9842, 2^61)
    let dot_a = add64(p.0, &p.1, p.0, &p.1);
    assert_eq!(dot_a, (9843, pow2(61)), "dot2_64 2x1.5^2 -> (9843,2^61)");

    let q = mul64(9841, &big(0), 9841, &big(0)); // (9841, 0)
    let dot_b = add64(p.0, &p.1, q.0, &q.1);
    assert_eq!(
        dot_b,
        (9842, pow2(63) + pow2(61)),
        "dot2_64 1.5^2+1.0^2 -> (9842, 2^63+2^61)"
    );
}

#[test]
fn gft_dot4_64_matches_the_iverilog_kat() {
    // dot4 = ((m0+m1)+(m2+m3)), the reduction tree of gft_dot4_64.v.
    // 4x1.5^2 -> (9844, 2^61) = 9.0 ; {1.5^2,1.0^2,1.5^2,1.0^2} -> (9843, 2^63+2^61) = 6.5.
    let p = mul64(9841, &pow2(63), 9841, &pow2(63)); // 1.5^2 = (9842, 2^61)
    let z = mul64(9841, &big(0), 9841, &big(0)); // 1.0^2 = (9841, 0)

    let s01 = add64(p.0, &p.1, p.0, &p.1);
    let s23 = add64(p.0, &p.1, p.0, &p.1);
    let top = add64(s01.0, &s01.1, s23.0, &s23.1);
    assert_eq!(top, (9844, pow2(61)), "dot4_64 4x1.5^2 -> (9844,2^61)=9.0");

    let m01 = add64(p.0, &p.1, z.0, &z.1); // 1.5^2 + 1.0^2 = (9842, 2^63+2^61)
    let m23 = add64(p.0, &p.1, z.0, &z.1);
    let mtop = add64(m01.0, &m01.1, m23.0, &m23.1);
    assert_eq!(
        mtop,
        (9843, pow2(63) + pow2(61)),
        "dot4_64 mixed -> (9843, 2^63+2^61)=6.5"
    );
}
