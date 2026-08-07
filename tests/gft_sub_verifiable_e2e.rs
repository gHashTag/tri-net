//! gft_sub_verifiable_e2e -- carry GF-T SUBTRACT through the whole ring, the same recompute-and-
//! slash the GF-T64 multiply e2e (gft64_verifiable_compute_e2e) proves, but for the operation that
//! was the last to get a cross-instrument twin (gft_sub_kat_cross). Subtract is where cancellation
//! bugs hide, so binding it into receipt -> challenge -> settle matters: an executor that returns a
//! wrong difference must be slashed by a challenger who RECOMPUTES gft_sub, not merely trusted.
//!
//!   assign (skill 0xA6.. = GF-T16 -> rung Et4)  ->  executor computes gft_sub(a,b) and signs a
//!   receipt over (Et, result)  ->  a challenger RECOMPUTES gft_sub(a,b) and compares  ->  settle
//!   pays the rung width only on an honest difference.
//!
//! Honest flow is paid; a wrong difference is slashed by the real recompute; a wrong-rung splice
//! (GF-T8 header over a GF-T16 receipt) is rejected before any recompute.

// ---- real GF-T16 subtract (transcribed from fpga/gft/gft_sub.v; see gft_sub_kat_cross) ----
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
fn norm_sig(v: u32, hb: u32, mant_bits: u32) -> u32 {
    if hb >= mant_bits {
        v >> ((hb - mant_bits) & 0x1f)
    } else {
        v << ((mant_bits - hb) & 0x1f)
    }
}
fn gft_sub(
    ao: u32,
    am: u32,
    bo: u32,
    bm: u32,
    mant_one: u32,
    mant_bits: u32,
    align_cap: u32,
) -> (u32, u32) {
    let a_ge = ao > bo || (ao == bo && am >= bm);
    let (hi_off, hi_m, lo_off, lo_m) = if a_ge {
        (ao, am, bo, bm)
    } else {
        (bo, bm, ao, am)
    };
    let d = hi_off - lo_off;
    let far_off = if hi_m >= 1 {
        hi_off
    } else {
        hi_off.saturating_sub(1)
    };
    let far_m = if hi_m >= 1 { hi_m - 1 } else { mant_one - 1 };
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
/// GF-T16 subtract (mant_one 512, mant_bits 9, align_cap 22).
fn sub16(ao: u32, am: u32, bo: u32, bm: u32) -> (u32, u32) {
    gft_sub(ao, am, bo, bm, 512, 9, 22)
}

// ---- ring layers (same shape as gft64_verifiable_compute_e2e) ----
fn mix32(x: u32) -> u32 {
    let mut h = x ^ 0x9E37_79B9;
    h = h.wrapping_mul(0x85EB_CA77);
    h ^= h >> 15;
    h
}
fn result_fp(r: (u32, u32)) -> u32 {
    mix32(r.0 ^ mix32(r.1).rotate_left(11))
}
fn receipt_leaf(gf_et: u32, result_fp: u32) -> u32 {
    mix32(mix32(result_fp) ^ gf_et.rotate_left(13))
}
/// Wire header skill -> rung Et (0xA6.. = GF-T16 -> 4; 0xA8.. = GF-T8 -> 3).
fn skill_rung_et(skill_hi: u32) -> u32 {
    match skill_hi {
        0xA6 => 4,
        0xA8 => 3,
        _ => 0,
    }
}

const RESOLVE_HONEST: u32 = 0;
const RESOLVE_SLASH: u32 = 1;
const RESOLVE_RUNG_MISMATCH: u32 = 6;

/// Verifier: derive Et from the header, recompute gft_sub on the committed operands, compare leaves.
#[allow(clippy::too_many_arguments)]
fn resolve(
    header_skill_hi: u32,
    ao: u32,
    am: u32,
    bo: u32,
    bm: u32,
    executor_leaf: u32,
    executor_committed_et: u32,
) -> u32 {
    let header_et = skill_rung_et(header_skill_hi);
    if header_et == 0 || header_et != executor_committed_et {
        return RESOLVE_RUNG_MISMATCH;
    }
    let recomputed = sub16(ao, am, bo, bm);
    let recomputed_leaf = receipt_leaf(header_et, result_fp(recomputed));
    if recomputed_leaf == executor_leaf {
        RESOLVE_HONEST
    } else {
        RESOLVE_SLASH
    }
}

fn settle(balance: u32, verdict: u32, width: u32) -> u32 {
    if verdict == RESOLVE_HONEST {
        balance + width
    } else {
        balance
    }
}

#[test]
fn an_honest_gft16_subtract_flows_through_the_whole_ring() {
    // Executor assigned GF-T16 (0xA6), computes 3.0-1.0=2.0 -> (41,0) and signs the honest leaf.
    let result = sub16(41, 256, 40, 0);
    assert_eq!(result, (41, 0), "GF-T16 3.0-1.0=2.0");
    let leaf = receipt_leaf(4, result_fp(result));
    let verdict = resolve(0xA6, 41, 256, 40, 0, leaf, 4);
    assert_eq!(
        verdict, RESOLVE_HONEST,
        "honest difference survives the recompute"
    );
    assert_eq!(
        settle(1000, verdict, 16),
        1016,
        "an honest GF-T16 op pays width 16"
    );
}

#[test]
fn a_wrong_difference_is_slashed_by_the_real_recompute() {
    // Executor commits a WRONG difference (claims (40,0)=1.0 instead of (41,0)=2.0).
    let lying_leaf = receipt_leaf(4, result_fp((40, 0)));
    let verdict = resolve(0xA6, 41, 256, 40, 0, lying_leaf, 4);
    assert_eq!(
        verdict, RESOLVE_SLASH,
        "the real gft_sub recompute catches the wrong difference"
    );
    assert_eq!(settle(1000, verdict, 16), 1000, "a slashed op pays nothing");
}

#[test]
fn a_wrong_rung_splice_is_rejected() {
    let result = sub16(41, 256, 40, 0);
    let leaf = receipt_leaf(4, result_fp(result)); // committed at GF-T16 (Et4)
                                                   // A relay retags the header to GF-T8 (0xA8 -> Et3); it no longer matches the committed Et4.
    let verdict = resolve(0xA8, 41, 256, 40, 0, leaf, 4);
    assert_eq!(
        verdict, RESOLVE_RUNG_MISMATCH,
        "GF-T8 header over a GF-T16 receipt -> rung mismatch"
    );
    assert_eq!(
        settle(1000, verdict, 16),
        1000,
        "a rung-mismatched op is not paid"
    );
}
