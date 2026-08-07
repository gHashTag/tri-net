//! gft64_verifiable_compute_e2e -- the whole ring, end to end, on REAL GF-T64 arithmetic. Earlier
//! end-to-end tests (gft_rung_end_to_end) used an abstract result; this drives the actual
//! gft_mul64 (cross-checked against silicon in gft_silicon_kat_cross) through the full chain:
//!
//!   assign (wire skill 0xA311 -> rung Et9)  ->  executor computes gft_mul64(a,b) and signs a
//!   receipt over (Et, result)  ->  a challenger RECOMPUTES gft_mul64(a,b) and compares (the
//!   recompute-and-slash core)  ->  settle pays the rung's width on an honest result.
//!
//! So a cheating executor (wrong GF-T64 result) is slashed by the real recompute, a wrong-rung
//! splice (GF-T16 header over a GF-T64 receipt) is rejected, and only an honest GF-T64 op is paid.

use num_bigint::BigUint;

// ---- real GF-T64 multiply (transcribed from fpga/gft/gft_mul64.v) ----
fn pow2(k: u32) -> BigUint {
    BigUint::from(1u32) << k as usize
}
fn gft_mul64(a_off: u32, a_mant: &BigUint, b_off: u32, b_mant: &BigUint) -> (u32, BigUint) {
    let m1 = pow2(64);
    let (bias, omax) = (9841u32, 19682u32);
    let prod = (&m1 + a_mant) * (&m1 + b_mant);
    let thresh = (&m1 * 2u32) * &m1;
    let carry: u32 = if prod >= thresh { 1 } else { 0 };
    let sum = a_off + b_off + carry;
    let off = if sum < bias {
        0
    } else {
        let r = sum - bias;
        if r >= omax {
            omax
        } else {
            r
        }
    };
    let mant = if carry == 1 {
        &prod / (&m1 * 2u32) - &m1
    } else {
        &prod / &m1 - &m1
    };
    (off, mant)
}

// ---- ring layers ----
fn mix32(x: u32) -> u32 {
    let mut h = x ^ 0x9E37_79B9;
    h = h.wrapping_mul(0x85EB_CA77);
    h ^= h >> 15;
    h
}
/// A 32-bit fingerprint of a GF-T64 result (offset + low words of the mantissa).
fn result_fp(r: &(u32, BigUint)) -> u32 {
    let digits = r.1.to_u32_digits();
    let lo = *digits.first().unwrap_or(&0);
    let hi = *digits.get(1).unwrap_or(&0);
    mix32(r.0 ^ mix32(lo) ^ mix32(hi).rotate_left(11))
}
/// Receipt leaf binds the rung Et and the result fingerprint (models receipt_leaf_gf_rung).
fn receipt_leaf(gf_et: u32, result_fp: u32) -> u32 {
    mix32(mix32(result_fp) ^ gf_et.rotate_left(13))
}
/// Wire header skill -> rung Et (0xA3.. = GF-T64 -> 9; 0xA6.. = GF-T16 -> 4).
fn skill_rung_et(skill_hi: u32) -> u32 {
    match skill_hi {
        0xA3 => 9,
        0xA6 => 4,
        _ => 0,
    }
}

const RESOLVE_HONEST: u32 = 0;
const RESOLVE_SLASH: u32 = 1;
const RESOLVE_RUNG_MISMATCH: u32 = 6;

/// The verifier: derive Et from the header, recompute gft_mul64 on the committed operands, and
/// compare the recomputed leaf to the executor's. Returns the ring verdict.
fn resolve(
    header_skill_hi: u32,
    a_off: u32,
    a_mant: &BigUint,
    b_off: u32,
    b_mant: &BigUint,
    executor_leaf: u32,
    executor_committed_et: u32,
) -> u32 {
    let header_et = skill_rung_et(header_skill_hi);
    if header_et == 0 || header_et != executor_committed_et {
        return RESOLVE_RUNG_MISMATCH; // unknown/wrong rung -> no slash
    }
    let recomputed = gft_mul64(a_off, a_mant, b_off, b_mant);
    let recomputed_leaf = receipt_leaf(header_et, result_fp(&recomputed));
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
fn an_honest_gft64_op_flows_through_the_whole_ring() {
    // Executor is assigned GF-T64 (header 0xA3), computes 1.5*1.5 and signs the honest leaf.
    let (a, b) = (pow2(63), pow2(63)); // both 1.5 = (9841, 2^63)
    let result = gft_mul64(9841, &a, 9841, &b); // (9842, 2^61)
    assert_eq!(result, (9842, pow2(61)), "the real GF-T64 op");
    let leaf = receipt_leaf(9, result_fp(&result));
    let verdict = resolve(0xA3, 9841, &a, 9841, &b, leaf, 9);
    assert_eq!(
        verdict, RESOLVE_HONEST,
        "honest GF-T64 result survives the recompute"
    );
    assert_eq!(
        settle(1000, verdict, 64),
        1064,
        "an honest GF-T64 op pays width 64"
    );
}

#[test]
fn a_cheating_executor_is_slashed_by_the_real_recompute() {
    let (a, b) = (pow2(63), pow2(63));
    // Executor commits a WRONG result (claims 2.0 -> (9842, 0) instead of 2.25 -> (9842, 2^61)).
    let wrong = (9842u32, BigUint::from(0u32));
    let lying_leaf = receipt_leaf(9, result_fp(&wrong));
    let verdict = resolve(0xA3, 9841, &a, 9841, &b, lying_leaf, 9);
    assert_eq!(
        verdict, RESOLVE_SLASH,
        "the real gft_mul64 recompute catches the wrong result"
    );
    assert_eq!(settle(1000, verdict, 64), 1000, "a slashed op pays nothing");
}

#[test]
fn a_wrong_rung_splice_is_rejected() {
    let (a, b) = (pow2(63), pow2(63));
    let result = gft_mul64(9841, &a, 9841, &b);
    let leaf = receipt_leaf(9, result_fp(&result)); // committed at GF-T64 (Et9)
                                                    // A relay retags the header to GF-T16 (0xA6 -> Et4); it no longer matches the committed Et9.
    let verdict = resolve(0xA6, 9841, &a, 9841, &b, leaf, 9);
    assert_eq!(
        verdict, RESOLVE_RUNG_MISMATCH,
        "GF-T16 header over a GF-T64 receipt -> rung mismatch"
    );
    assert_eq!(
        settle(1000, verdict, 64),
        1000,
        "a rung-mismatched op is not paid"
    );
}
