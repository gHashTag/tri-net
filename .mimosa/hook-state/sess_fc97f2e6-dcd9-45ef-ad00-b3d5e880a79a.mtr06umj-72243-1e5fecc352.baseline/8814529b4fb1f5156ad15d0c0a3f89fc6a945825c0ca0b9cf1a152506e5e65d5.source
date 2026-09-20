//! gfvalid_settle_integration -- the validity gate and the mint gate compose: a GF result flows
//! through payable_flag (tri_compute_gfvalid, guarded by gfvalid_finiteness) INTO settle_canonical
//! (tri_compute_settle, guarded by settle_mint_gate). Each is unit-guarded; this pins that a garbage
//! result (inf/nan, or a GF-T offset out of range / on the special row) produces payable=0 and
//! therefore mints NOTHING end to end, while a fresh signed finite result mints its width. The point
//! is the SAME result value drives both gates consistently -- garbage cannot be finite-here and paid-
//! there.

const REWARD_PER_GF_OP: u32 = 1;
const FMT_GF_BINARY: u32 = 0;
const FMT_GFT: u32 = 1;

// ---- gfvalid: payable_flag (transcribed) ----
fn payable_flag(
    fmt_family: u32,
    gf_result: u32,
    exp_bits: u32,
    mant_bits: u32,
    has_inf: u32,
    offset_max: u32,
) -> u32 {
    let exp_mask = (1u32 << exp_bits) - 1;
    let exp = (gf_result >> mant_bits) & exp_mask;
    if fmt_family == FMT_GFT {
        u32::from(gf_result < offset_max)
    } else if has_inf == 1 {
        u32::from(exp != exp_mask)
    } else {
        1
    }
}

// ---- settle: the mint gate (transcribed) ----
fn balance_add(bal: u32, reward: u32) -> u32 {
    bal.saturating_add(reward)
}
fn compute_reward(gf_width: u32, fresh: u32) -> u32 {
    if fresh == 1 {
        gf_width * REWARD_PER_GF_OP
    } else {
        0
    }
}
#[allow(clippy::too_many_arguments)]
fn settle_canonical(
    prev_balance: u32,
    gf_width: u32,
    sig_ok: u32,
    fresh: u32,
    already_settled: u32,
    fmt_family: u32,
    gf_result: u32,
    exp_bits: u32,
    mant_bits: u32,
    has_inf: u32,
    offset_max: u32,
) -> u32 {
    let payable = payable_flag(
        fmt_family, gf_result, exp_bits, mant_bits, has_inf, offset_max,
    );
    let credit = if sig_ok == 1 && already_settled == 0 && fresh == 1 {
        compute_reward(gf_width, payable)
    } else {
        0
    };
    balance_add(prev_balance, credit)
}

#[test]
fn a_finite_result_is_payable_in_both_gates_and_mints_its_width() {
    // Binary GF16 finite 0x4200: payable at gfvalid AND paid at settle.
    assert_eq!(
        payable_flag(FMT_GF_BINARY, 0x4200, 6, 9, 1, 0),
        1,
        "gfvalid: finite -> payable"
    );
    assert_eq!(
        settle_canonical(100, 16, 1, 1, 0, FMT_GF_BINARY, 0x4200, 6, 9, 1, 0),
        116,
        "settle: pays width 16"
    );
    // GF-T16 offset 40 (< offset_max 80): payable and paid.
    assert_eq!(
        payable_flag(FMT_GFT, 40, 0, 0, 0, 80),
        1,
        "gfvalid: in-range GF-T -> payable"
    );
    assert_eq!(
        settle_canonical(100, 16, 1, 1, 0, FMT_GFT, 40, 0, 0, 0, 80),
        116,
        "settle: pays"
    );
}

#[test]
fn garbage_is_not_payable_at_gfvalid_and_therefore_mints_nothing_at_settle() {
    // The composition invariant: whatever gfvalid classes not-payable, settle mints 0 for -- garbage
    // cannot slip through by being judged differently at the two gates.
    let cases: &[(u32, u32, u32, u32, u32, u32, &str)] = &[
        (FMT_GF_BINARY, 0x7E00, 6, 9, 1, 0, "GF16 +inf"),
        (FMT_GF_BINARY, 0x7E01, 6, 9, 1, 0, "GF16 NaN"),
        (
            FMT_GF_BINARY,
            0x70,
            3,
            4,
            1,
            0,
            "GF8 all-ones exp (with has_inf)",
        ),
        (
            FMT_GFT,
            80,
            0,
            0,
            0,
            80,
            "GF-T16 special row (offset == offset_max)",
        ),
        (FMT_GFT, 200, 0, 0, 0, 80, "GF-T16 out-of-range offset"),
    ];
    for &(fam, res, eb, mb, hi, omax, name) in cases {
        assert_eq!(
            payable_flag(fam, res, eb, mb, hi, omax),
            0,
            "gfvalid: {name} is NOT payable"
        );
        // Fresh, signed, unsettled -- every gate open EXCEPT validity -> still mints 0.
        assert_eq!(
            settle_canonical(100, 16, 1, 1, 0, fam, res, eb, mb, hi, omax),
            100,
            "settle: {name} mints nothing (payable=0)"
        );
    }
}

#[test]
fn a_max_exponent_gf8_result_is_payable_end_to_end_when_the_format_has_no_special_row() {
    // The dual of the garbage case: a GF8 max-exp result is a NORMAL value (has_inf=0), so gfvalid
    // classes it payable and settle pays width 8 -- valid work is not wrongly zeroed by a GF16 rule.
    assert_eq!(
        payable_flag(FMT_GF_BINARY, 0x70, 3, 4, 0, 0),
        1,
        "GF8 max-exp normal (no special row)"
    );
    assert_eq!(
        settle_canonical(100, 8, 1, 1, 0, FMT_GF_BINARY, 0x70, 3, 4, 0, 0),
        108,
        "settle pays width 8"
    );
}
