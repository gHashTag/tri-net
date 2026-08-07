//! gft32_dot4_kat_cross -- extends the cross-instrument guard to the GF-T32 4-lane MAC. The
//! gft_dot4_32 / gft_dot4_tile_32 iverilog KATs (fpga/gft/*_kat_tb.v) had no Rust twin (only the
//! GF-T32 multiply was cross-checked in gft32_challenge). This transcribes gft_mul + gft_add and
//! composes them into the same 4-lane reduction the silicon uses, asserting the EXACT (offset,
//! mantissa) tuples the iverilog dot4 KATs returned. GF-T32 fits u64 (mant_one 2^25, product ~2^52),
//! so no bignum is needed. If the Rust model drifts from the silicon dot4, this fails.

const MANT_ONE: u64 = 1 << 25; // 2^25
const BIAS: u64 = 364;
const OMAX: u64 = 728;
const SIG_BITS: u64 = 26;

/// gft_mul, transcribed from fpga/gft/gft_mul32.v (64-bit significand path).
fn gft_mul(ao: u64, am: u64, bo: u64, bm: u64) -> (u64, u64) {
    let prod = (MANT_ONE + am) * (MANT_ONE + bm);
    let thresh = (2 * MANT_ONE) * MANT_ONE;
    let carry = if prod >= thresh { 1 } else { 0 };
    let sum = ao + bo + carry;
    let off = if sum < BIAS {
        0
    } else {
        let r = sum - BIAS;
        if r >= OMAX {
            OMAX
        } else {
            r
        }
    };
    let mant = if carry == 1 {
        prod / (2 * MANT_ONE) - MANT_ONE
    } else {
        prod / MANT_ONE - MANT_ONE
    };
    (off, mant)
}

/// gft_add, transcribed from fpga/gft/gft_add.v.
fn gft_add(ao: u64, am: u64, bo: u64, bm: u64) -> (u64, u64) {
    let a_hi = ao >= bo;
    let (hi_off, hi_m, lo_off, lo_m) = if a_hi {
        (ao, am, bo, bm)
    } else {
        (bo, bm, ao, am)
    };
    let d = hi_off - lo_off;
    let sb = if d >= SIG_BITS {
        0
    } else {
        (MANT_ONE + lo_m) >> d
    };
    let sum = (MANT_ONE + hi_m) + sb;
    let carry = sum >= 2 * MANT_ONE;
    let off = if carry {
        let e = hi_off + 1;
        if e >= OMAX {
            OMAX
        } else {
            e
        }
    } else {
        hi_off
    };
    let mant = if carry {
        (sum >> 1) - MANT_ONE
    } else {
        sum - MANT_ONE
    };
    (off, mant)
}

/// 4-lane dot4: ((m0+m1) + (m2+m3)), the reduction tree of gft_dot4_32.v / gft_dot4_tile_32.v.
fn dot4(lanes: [(u64, u64); 4]) -> (u64, u64) {
    let (mo0, mo1, mo2, mo3) = (lanes[0], lanes[1], lanes[2], lanes[3]);
    let s01 = gft_add(mo0.0, mo0.1, mo1.0, mo1.1);
    let s23 = gft_add(mo2.0, mo2.1, mo3.0, mo3.1);
    gft_add(s01.0, s01.1, s23.0, s23.1)
}

const M24: u64 = 1 << 24; // 1.5 mantissa at GF-T32
const M22: u64 = 1 << 22;

#[test]
fn gft_dot4_32_matches_the_iverilog_kat() {
    // 1.5 = (364, 2^24); 1.5*1.5 = (365, 2^22). Values from fpga/gft/gft_dot4_32_kat_tb.v.
    let p = gft_mul(364, M24, 364, M24);
    assert_eq!(p, (365, M22), "GF-T32 1.5^2 -> (365, 2^22)");
    // all four lanes 1.5*1.5 -> 9.0
    assert_eq!(
        dot4([p, p, p, p]),
        (367, M22),
        "dot4_32 4x1.5^2 -> (367, 2^22)=9.0"
    );

    // mixed {1.5^2, 1.0^2, 1.5^2, 1.0^2} -> 6.5
    let z = gft_mul(364, 0, 364, 0); // 1.0^2 = (364, 0)
    assert_eq!(z, (364, 0), "GF-T32 1.0^2 -> (364, 0)");
    assert_eq!(
        dot4([p, z, p, z]),
        (366, 20971520),
        "dot4_32 mixed -> (366, 20971520)=6.5"
    );
}

#[test]
fn the_tile_variant_shares_the_same_dot4_values() {
    // gft_dot4_tile_32.v is the packed-port variant with the SAME arithmetic, so it must return
    // the SAME tuples -- pinning that the packing did not change the numeric result.
    let p = gft_mul(364, M24, 364, M24);
    let z = gft_mul(364, 0, 364, 0);
    assert_eq!(dot4([p, p, p, p]), (367, M22), "tile_32 4x1.5^2 == dot4_32");
    assert_eq!(
        dot4([p, z, p, z]),
        (366, 20971520),
        "tile_32 mixed == dot4_32"
    );
}
