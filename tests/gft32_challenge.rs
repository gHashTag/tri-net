//! gft32_challenge -- verifiable compute for the TOP rung, GF-T32. Extends the
//! recompute-and-slash guarantee (gft_compute_challenge, GF-T16) to GF-T32, whose
//! significand product reaches ~2^52 and needs a 64-bit datapath (fpga/gft/gft_mul32.v).
//!
//! The oracle is transcribed from tri_gft_arith's gft_mul_*_u64 (also the RTL in
//! gft_mul32.v). GF-T32: bias 364, offset_max 728, mant_one 2^25; value =
//! (1 + M/2^25) * 2^(offset - 364). It also proves WHY the wide datapath matters for
//! CORRECTNESS: a naive 32-bit multiply overflows and its result is not just different
//! but wrong -- and the challenge slashes it.

const BIAS: u64 = 364;
const OFFSET_MAX: u64 = 728;
const MANT_ONE: u64 = 1 << 25; // 2^25

/// Correct GF-T32 multiply (64-bit product path).
fn mul32(oa: u64, ma: u64, ob: u64, mb: u64) -> (u64, u64) {
    let prod: u64 = (MANT_ONE + ma) * (MANT_ONE + mb); // up to ~2^52, fits u64
    let carry = if prod >= (2 * MANT_ONE) * MANT_ONE {
        1
    } else {
        0
    };
    let mant = if carry == 1 {
        (prod / (2 * MANT_ONE)) - MANT_ONE
    } else {
        (prod / MANT_ONE) - MANT_ONE
    };
    let sum = oa + ob + carry;
    let off = if sum < BIAS {
        0
    } else {
        let r = sum - BIAS;
        if r >= OFFSET_MAX {
            OFFSET_MAX
        } else {
            r
        }
    };
    (off, mant)
}

/// A wrong-but-plausible multiplier that truncates the significand product to 32 bits,
/// exactly the silent bug in the GF-T16-width gft_mul.v when fed GF-T32 operands.
fn mul32_truncated_bug(oa: u64, ma: u64, ob: u64, mb: u64) -> (u64, u64) {
    let full: u64 = (MANT_ONE + ma) * (MANT_ONE + mb);
    let prod = full & 0xFFFF_FFFF; // 32-bit wrap, like a [31:0] wire
    let carry = if prod >= (2 * MANT_ONE) * MANT_ONE {
        1
    } else {
        0
    };
    let mant = if carry == 1 {
        (prod / (2 * MANT_ONE)).wrapping_sub(MANT_ONE)
    } else {
        (prod / MANT_ONE).wrapping_sub(MANT_ONE)
    };
    let sum = oa + ob + carry;
    let off = if sum < BIAS {
        0
    } else {
        let r = sum - BIAS;
        if r >= OFFSET_MAX {
            OFFSET_MAX
        } else {
            r
        }
    };
    (off, mant & 0x1FF_FFFF) // 25-bit field
}

fn verify(oa: u64, ma: u64, ob: u64, mb: u64, claim: (u64, u64)) -> bool {
    mul32(oa, ma, ob, mb) == claim
}
fn slashes(oa: u64, ma: u64, ob: u64, mb: u64, claim: (u64, u64)) -> bool {
    !verify(oa, ma, ob, mb, claim)
}

const M24: u64 = 1 << 24; // 2^24
const M23: u64 = 1 << 23; // 2^23
const M22: u64 = 1 << 22; // 2^22

#[test]
fn kat_matches_the_rtl() {
    // Same golden values the iverilog gft_mul32_tb checks.
    assert_eq!(mul32(364, 0, 364, 0), (364, 0), "1*1 = 1");
    assert_eq!(mul32(364, M24, 364, M24), (365, M22), "1.5^2 = 2.25");
    assert_eq!(mul32(364, 0, 365, 0), (365, 0), "1*2 = 2");
    assert_eq!(mul32(400, M23, 400, M23), (436, 18874368), "(1.25*2^36)^2");
}

#[test]
fn honest_result_is_accepted() {
    for oa in (300..430u64).step_by(9) {
        for ob in (300..430u64).step_by(11) {
            for &ma in &[0u64, 1, M23, M24, M24 + M23, MANT_ONE - 1] {
                for &mb in &[0u64, 7, M22, M24, MANT_ONE - 1] {
                    let c = mul32(oa, ma, ob, mb);
                    assert!(
                        !slashes(oa, ma, ob, mb, c),
                        "honest claim slashed at ({oa},{ma})x({ob},{mb})"
                    );
                }
            }
        }
    }
}

#[test]
fn wrong_result_is_slashed() {
    for oa in (350..400u64).step_by(7) {
        for ob in (350..400u64).step_by(7) {
            for &ma in &[0u64, M23, M24, MANT_ONE - 1] {
                for &mb in &[0u64, M22, M24, MANT_ONE - 1] {
                    let (o, m) = mul32(oa, ma, ob, mb);
                    assert!(slashes(oa, ma, ob, mb, (o + 1, m)), "off+1 not slashed");
                    assert!(slashes(oa, ma, ob, mb, (o, m + 1)), "mant+1 not slashed");
                }
            }
        }
    }
}

#[test]
fn the_naive_32bit_multiplier_is_slashed() {
    // The bug is not academic: the 32-bit-truncated product yields a WRONG result on a
    // real GF-T32 vector, and the challenge catches it. (364,2^24)^2 truly = (365,2^22).
    let correct = mul32(364, M24, 364, M24);
    let buggy = mul32_truncated_bug(364, M24, 364, M24);
    assert_eq!(correct, (365, M22));
    assert_ne!(
        buggy, correct,
        "the 32-bit truncation must produce a different (wrong) result"
    );
    assert!(
        slashes(364, M24, 364, M24, buggy),
        "a naive 32-bit multiplier's result must be slashed"
    );
}
