//! gft_compute_challenge -- executable proof of the compute-CORRECTNESS layer: an honest verifier
//! recomputes a GF-T multiply and slashes a wrong result.
//!
//! gft_receipt_binding proves a result is BOUND to its input (can't be swapped). This proves the
//! next thing verifiable compute needs: the bound result is ARITHMETICALLY CORRECT. The optimistic
//! ring accepts a claimed product on faith and lets any peer challenge it; the challenge recomputes
//! `gft_mul` from the operands and, if the claim disagrees, the executor is slashed.
//!
//! The recompute here is transcribed VERBATIM (integer, no float) from specs/tri_gft_arith.t27 --
//! gft_mul_mant_carry_p / gft_mul_mant_p / gft_mul_offset_full_p / verify_gft_mul_full_p -- so the
//! verifier IS the spec's arithmetic, not a re-derivation. Cross-checked against the same KATs the
//! merged iverilog RTL uses: GF-T16 (41,0)^2 -> (42,0) and (41,256)^2 -> (43,64).
//!
//! Scope, honestly: this validates the spec's multiply + fraud verdict against the primitives and
//! KATs, not the un-committed gen/rust (needs t27c). It is the CI-runnable guardrail for "a wrong
//! GF-T result is caught". Run: `cargo test --test gft_compute_challenge`.

// ---- Transcribed VERBATIM from specs/tri_gft_arith.t27 (u64 to avoid mantissa-product overflow). ----

/// gft_mul_mant_carry_p: 1 if the mantissa product overflows [1,2) into [2,4).
fn mul_carry(ma: u64, mb: u64, mant_one: u64) -> u64 {
    let prod = (mant_one + ma) * (mant_one + mb);
    if prod >= (2 * mant_one) * mant_one {
        1
    } else {
        0
    }
}

/// gft_mul_mant_p: the result mantissa (normalized back into [0, mant_one)).
fn mul_mant(ma: u64, mb: u64, mant_one: u64) -> u64 {
    let prod = (mant_one + ma) * (mant_one + mb);
    if prod >= (2 * mant_one) * mant_one {
        (prod / (2 * mant_one)) - mant_one
    } else {
        (prod / mant_one) - mant_one
    }
}

/// gft_mul_offset_full_p: the result exponent offset, carry-corrected and rung-clamped.
fn mul_offset(
    oa: u64,
    ma: u64,
    ob: u64,
    mb: u64,
    bias: u64,
    offset_max: u64,
    mant_one: u64,
) -> u64 {
    let carry = mul_carry(ma, mb, mant_one);
    let sum = oa + ob + carry;
    if sum < bias {
        0
    } else {
        let result = sum - bias;
        if result >= offset_max {
            offset_max
        } else {
            result
        }
    }
}

/// verify_gft_mul_full_p: does a claimed (offset, mant) match the honest recompute?
fn verify_full(
    oa: u64,
    ma: u64,
    ob: u64,
    mb: u64,
    claimed_o: u64,
    claimed_m: u64,
    bias: u64,
    offset_max: u64,
    mant_one: u64,
) -> bool {
    mul_offset(oa, ma, ob, mb, bias, offset_max, mant_one) == claimed_o
        && mul_mant(ma, mb, mant_one) == claimed_m
}

// ---- GF-T16 rung parameters. ----
const BIAS: u64 = 40;
const OFFSET_MAX: u64 = 80;
const MANT_ONE: u64 = 512;

/// The honest executor's claim for a * b.
fn honest_mul(oa: u64, ma: u64, ob: u64, mb: u64) -> (u64, u64) {
    (
        mul_offset(oa, ma, ob, mb, BIAS, OFFSET_MAX, MANT_ONE),
        mul_mant(ma, mb, MANT_ONE),
    )
}

/// The challenge verdict: TRUE = the executor should be SLASHED (claim is wrong).
fn slashes(oa: u64, ma: u64, ob: u64, mb: u64, claim: (u64, u64)) -> bool {
    !verify_full(oa, ma, ob, mb, claim.0, claim.1, BIAS, OFFSET_MAX, MANT_ONE)
}

#[test]
fn kat_matches_the_rtl() {
    // Exact same KATs the merged iverilog gft_mul_kat_tb.v checks.
    assert_eq!(honest_mul(41, 0, 41, 0), (42, 0), "GF-T16 (41,0)^2");
    assert_eq!(honest_mul(41, 256, 41, 256), (43, 64), "GF-T16 (41,256)^2");
}

#[test]
fn honest_result_is_accepted() {
    // A correct executor is never slashed, across a full operand sweep.
    for oa in 20..60u64 {
        for ob in 20..60u64 {
            for &ma in &[0u64, 1, 100, 256, 400, 511] {
                for &mb in &[0u64, 7, 200, 256, 333, 511] {
                    let claim = honest_mul(oa, ma, ob, mb);
                    assert!(
                        !slashes(oa, ma, ob, mb, claim),
                        "honest claim slashed for ({oa},{ma})x({ob},{mb})"
                    );
                }
            }
        }
    }
}

#[test]
fn wrong_result_is_slashed() {
    // Any perturbation of a correct result -- off-by-one exponent OR mantissa -- is caught.
    for oa in 20..60u64 {
        for ob in 20..60u64 {
            for &ma in &[0u64, 100, 256, 511] {
                for &mb in &[0u64, 200, 256, 511] {
                    let (o, m) = honest_mul(oa, ma, ob, mb);
                    // corrupt the exponent
                    assert!(
                        slashes(oa, ma, ob, mb, (o + 1, m)),
                        "off-by-one exponent not slashed for ({oa},{ma})x({ob},{mb})"
                    );
                    // corrupt the mantissa up
                    assert!(
                        slashes(oa, ma, ob, mb, (o, m + 1)),
                        "off-by-one mantissa(+) not slashed for ({oa},{ma})x({ob},{mb})"
                    );
                    // corrupt the mantissa down (when nonzero)
                    if m > 0 {
                        assert!(
                            slashes(oa, ma, ob, mb, (o, m - 1)),
                            "off-by-one mantissa(-) not slashed for ({oa},{ma})x({ob},{mb})"
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn a_plausible_forgery_is_still_slashed() {
    // A forger who returns a VALID-looking GF-T value (not garbage) but the wrong product is still
    // caught -- correctness is exact, not "close enough". (41,256)^2 is really (43,64); claim the
    // neighbouring (43,63) and (42,64).
    assert!(
        slashes(41, 256, 41, 256, (43, 63)),
        "near-miss mantissa must slash"
    );
    assert!(
        slashes(41, 256, 41, 256, (42, 64)),
        "near-miss exponent must slash"
    );
    // ...but the true product is accepted.
    assert!(
        !slashes(41, 256, 41, 256, (43, 64)),
        "the true product must NOT slash"
    );
}
