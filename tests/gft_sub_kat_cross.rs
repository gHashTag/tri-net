//! gft_sub_kat_cross -- the cross-instrument guard finally reaches GF-T SUBTRACT, the one ladder
//! operation that had an iverilog KAT (fpga/gft/gft_sub_kat_tb.v) but no Rust twin. Multiply, add
//! and the MACs are all cross-checked (gft_silicon_kat_cross / gft64_add_dot_kat_cross /
//! gft32_dot4_kat_cross); subtract was the gap. It is also the hardest rung arithmetic --
//! magnitude-difference with catastrophic cancellation, renormalize-by-leading-bit, a far path
//! (operands more than ALIGN_CAP apart) and underflow-to-zero -- so it is exactly where a silent
//! model/silicon drift would hide.
//!
//! This transcribes fpga/gft/gft_sub.v (the verified realization of specs/tri_gft_sub.t27's
//! gft_sub_offset_c_p + gft_sub_mant_c_p -- the SAME spec trinet_rung_verify runs over the wire)
//! and asserts the EXACT (offset, mantissa) tuples iverilog produced. The five official KAT rows
//! (gft_sub_kat_tb.v, GF-T16/8/4) are the primary cross-check; five more GF-T16 rows harvested
//! from iverilog on this same gft_sub.v extend coverage to the far path, a same-offset
//! cancellation (d=0) and the v==0 zero path, which the d=1 KAT never exercises.

/// Highest set-bit index of x (1..30, 0 if x < 2) -- the spec's hi_bit ladder in gft_sub.v.
fn hi_bit(x: u32) -> u32 {
    let mut hb = 0u32;
    let mut i: i32 = 30;
    while i >= 1 {
        if (x >> i) & 1 == 1 && hb == 0 {
            hb = i as u32;
        }
        i -= 1;
    }
    hb
}

/// Normalize v (top set bit at hb) to a (mant_bits+1)-bit significand -- gft_sub.v norm_sig.
fn norm_sig(v: u32, hb: u32, mant_bits: u32) -> u32 {
    if hb >= mant_bits {
        v >> ((hb - mant_bits) & 0x1f)
    } else {
        v << ((mant_bits - hb) & 0x1f)
    }
}

/// gft_sub, transcribed verbatim from fpga/gft/gft_sub.v. u32/[31:0] semantics: the near-path
/// significand `v` uses wrapping shift/sub to mirror the hardware's mod-2^32 wrap (only the far
/// path is taken when d >= ALIGN_CAP, so v's wrapped value is discarded there).
fn gft_sub(
    a_off: u32,
    a_mant: u32,
    b_off: u32,
    b_mant: u32,
    mant_one: u32,
    mant_bits: u32,
    align_cap: u32,
) -> (u32, u32) {
    // Order operands by magnitude: hi = larger (offset, then mantissa).
    let a_ge = a_off > b_off || (a_off == b_off && a_mant >= b_mant);
    let (hi_off, hi_m, lo_off, lo_m) = if a_ge {
        (a_off, a_mant, b_off, b_mant)
    } else {
        (b_off, b_mant, a_off, a_mant)
    };
    let d = hi_off - lo_off;

    // Far path (d >= ALIGN_CAP): the smaller operand is below one ULP -> hi minus one ULP.
    let far_off = if hi_m >= 1 {
        hi_off
    } else {
        // gft_sub.v: (hi_off >= 1) ? hi_off - 1 : 0 -- exactly saturating_sub(1).
        hi_off.saturating_sub(1)
    };
    let far_m = if hi_m >= 1 { hi_m - 1 } else { mant_one - 1 };

    // Near path: full-precision aligned difference, renormalized by the leading set bit.
    let v = (mant_one + hi_m)
        .wrapping_shl(d & 0x1f)
        .wrapping_sub(mant_one + lo_m);
    let hb = hi_bit(v);
    let underflow = lo_off + hb < mant_bits;
    let near_off = if v == 0 || underflow {
        0
    } else {
        lo_off + hb - mant_bits
    };
    let near_m = if v == 0 || underflow {
        0
    } else {
        norm_sig(v, hb, mant_bits) - mant_one
    };

    if d >= align_cap {
        (far_off, far_m)
    } else {
        (near_off, near_m)
    }
}

// Rung geometries, exactly as the KAT instantiates gft_sub (#(MANT_ONE, MANT_BITS), ALIGN_CAP=22).
fn sub16(ao: u32, am: u32, bo: u32, bm: u32) -> (u32, u32) {
    gft_sub(ao, am, bo, bm, 512, 9, 22)
}
fn sub8(ao: u32, am: u32, bo: u32, bm: u32) -> (u32, u32) {
    gft_sub(ao, am, bo, bm, 16, 4, 22)
}
fn sub4(ao: u32, am: u32, bo: u32, bm: u32) -> (u32, u32) {
    gft_sub(ao, am, bo, bm, 2, 1, 22)
}

#[test]
fn gft_sub_matches_the_iverilog_kat() {
    // The five official rows from fpga/gft/gft_sub_kat_tb.v -- "values the over-wire verifier accepts".
    assert_eq!(sub16(41, 0, 40, 0), (40, 0), "GF-T16 2.0-1.0=1.0");
    assert_eq!(sub16(41, 256, 40, 0), (41, 0), "GF-T16 3.0-1.0=2.0");
    assert_eq!(sub8(13, 8, 12, 0), (13, 0), "GF-T8 1.5-0.5=1.0");
    assert_eq!(sub8(14, 0, 13, 0), (13, 0), "GF-T8 2.0-1.0=1.0");
    assert_eq!(sub4(5, 0, 4, 0), (4, 0), "GF-T4 2.0-1.0=1.0");
}

#[test]
fn gft_sub_covers_the_far_cancel_and_zero_paths() {
    // Harvested from iverilog on the same gft_sub.v -- paths the d=1 KAT never reaches.
    // Same-offset cancellation (d=0): 3.0-2.0=1.0.
    assert_eq!(sub16(41, 256, 41, 0), (40, 0), "GF-T16 d=0 cancel 3.0-2.0");
    // Near path with d=2 and a two-bit significand: 4.0-1.0=3.0 -> (41,256).
    assert_eq!(sub16(42, 0, 40, 0), (41, 256), "GF-T16 4.0-1.0=3.0");
    // Far path (d=23 >= ALIGN_CAP), hi mantissa 0 -> hi_off-1, mant saturates to mant_one-1.
    assert_eq!(sub16(63, 0, 40, 0), (62, 511), "GF-T16 far, hi_m=0");
    // Far path, hi mantissa >= 1 -> hi_off, hi_m-1.
    assert_eq!(sub16(63, 256, 40, 0), (63, 255), "GF-T16 far, hi_m>=1");
    // Exact cancellation to zero (v==0): x - x = 0.
    assert_eq!(sub16(40, 0, 40, 0), (0, 0), "GF-T16 x-x=0");
}
