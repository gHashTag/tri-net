//! settle_mint_gate -- CI guard for the reward-COMPUTATION / mint authorization (specs/
//! tri_compute_settle.t27), the last money layer without a dedicated unit guard (per docs/
//! CI_GUARD_MAP.md). settle_canonical decides whether ANY reward is minted and HOW MUCH: a fresh,
//! signed, not-yet-settled receipt whose GF result is FINITE mints `gf_width * REWARD_PER_GF_OP`;
//! dropping any one of those four gates mints nothing. compute_reward and settle_checked were only
//! thinly referenced; the four-gate mint authorization, the width scaling, the fractional bps
//! weighting (with its u64 overflow guard), and the finiteness reject had no dedicated CI twin.

const REWARD_PER_GF_OP: u32 = 1;
const WORK_BPS_UNIT: u32 = 10000;
const FMT_GF_BINARY: u32 = 0;
const FMT_GFT: u32 = 1;

fn balance_add(bal: u32, reward: u32) -> u32 {
    // spec: sum = bal + reward; sum < bal ? 0xFFFFFFFF : sum -- exactly saturating_add.
    bal.saturating_add(reward)
}
fn compute_reward(gf_width: u32, fresh: u32) -> u32 {
    if fresh == 1 {
        gf_width * REWARD_PER_GF_OP
    } else {
        0
    }
}
fn compute_reward_fmt(gf_width: u32, fresh: u32, work_bps: u32) -> u32 {
    if fresh == 1 {
        let scaled = (gf_width as u64) * (work_bps as u64);
        (scaled / (WORK_BPS_UNIT as u64)) as u32
    } else {
        0
    }
}
/// Is the claimed GF result a payable (finite/in-range) value? (tri_compute_settle.payable_flag)
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
        u32::from(exp != exp_mask) // an all-ones exponent is inf/nan -> not payable
    } else {
        1
    }
}
/// The mint authorization: credit gf_width*REWARD iff sig_ok AND not-already-settled AND fresh AND
/// the result is payable; otherwise credit nothing. (tri_compute_settle.settle_canonical)
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
fn the_base_reward_scales_with_width_and_is_zero_on_stale() {
    assert_eq!(compute_reward(16, 1), 16, "a fresh GF16 op pays 16 $TRI");
    assert_eq!(
        compute_reward(32, 1),
        32,
        "a wider GF op pays proportionally more"
    );
    assert_eq!(compute_reward(16, 0), 0, "a replayed/stale receipt pays 0");
    assert_eq!(compute_reward(64, 1), 64, "GF-T64 pays 64");
}

#[test]
fn the_fractional_bps_weight_scales_and_never_overflows() {
    assert_eq!(
        compute_reward_fmt(16, 1, WORK_BPS_UNIT),
        16,
        "1.0x weight = full width reward"
    );
    assert_eq!(
        compute_reward_fmt(16, 1, 5000),
        8,
        "0.5x weight halves the reward"
    );
    assert_eq!(
        compute_reward_fmt(16, 1, 20000),
        32,
        "2.0x weight doubles it"
    );
    assert_eq!(
        compute_reward_fmt(16, 0, 20000),
        0,
        "stale pays nothing regardless of weight"
    );
    // gf_width * work_bps overflows u32 (e.g. 1e6 * 20000 = 2e10); the u64 widening keeps it exact.
    assert_eq!(
        compute_reward_fmt(1_000_000, 1, 20000),
        2_000_000,
        "u64 mulDiv exact at scale"
    );
    let bare = (1_000_000u32).wrapping_mul(20000) / WORK_BPS_UNIT;
    assert_ne!(
        compute_reward_fmt(1_000_000, 1, 20000),
        bare,
        "not the wrapped garbage"
    );
}

#[test]
fn settle_balance_is_saturating() {
    assert_eq!(
        balance_add(100, compute_reward(16, 1)),
        116,
        "fresh settle credits the reward"
    );
    assert_eq!(
        balance_add(0xFFFF_FFF0, 32),
        0xFFFF_FFFF,
        "credit that would overflow saturates, no wrap"
    );
}

#[test]
fn the_mint_gate_requires_all_four_conditions() {
    // Exhaustive over (sig_ok, not_settled, fresh, payable). A fresh finite GF16 result (0x4200) is
    // payable; an all-ones-exponent result (0x7E00) is not. Only the all-pass case mints the reward.
    let finite = 0x4200u32; // exp = (0x4200>>9)&0x3F = 0x21 != 0x3F -> finite
    let infinite = 0x7E00u32; // exp = 0x3F -> inf -> not payable
    for sig in 0..2u32 {
        for settled in 0..2u32 {
            for fresh in 0..2u32 {
                for &(result, payable) in &[(finite, true), (infinite, false)] {
                    let credited = settle_canonical(
                        100,
                        16,
                        sig,
                        fresh,
                        settled,
                        FMT_GF_BINARY,
                        result,
                        6,
                        9,
                        1,
                        0,
                    );
                    let should_pay = sig == 1 && settled == 0 && fresh == 1 && payable;
                    let expect = if should_pay { 116 } else { 100 };
                    assert_eq!(
                        credited, expect,
                        "sig={sig} settled={settled} fresh={fresh} payable={payable}"
                    );
                }
            }
        }
    }
}

#[test]
fn an_infinite_or_nan_result_mints_nothing_even_when_otherwise_valid() {
    // The anti-garbage gate: a fresh, signed, unsettled receipt still mints 0 if the result is inf/nan.
    assert_eq!(
        settle_canonical(100, 16, 1, 1, 0, FMT_GF_BINARY, 0x4200, 6, 9, 1, 0),
        116,
        "fresh finite GF16 pays 16"
    );
    assert_eq!(
        settle_canonical(100, 16, 1, 1, 0, FMT_GF_BINARY, 0x7E00, 6, 9, 1, 0),
        100,
        "inf pays nothing"
    );
    assert_eq!(
        settle_canonical(100, 16, 1, 1, 0, FMT_GF_BINARY, 0x7E01, 6, 9, 1, 0),
        100,
        "NaN pays nothing"
    );
    // GF8 (exp_bits 3, mant_bits 4): a fresh finite op pays width 8; inf (exp all-ones = 7) pays 0.
    assert_eq!(
        settle_canonical(100, 8, 1, 1, 0, FMT_GF_BINARY, 0x20, 3, 4, 1, 0),
        108,
        "GF8 fresh finite pays 8"
    );
    assert_eq!(
        settle_canonical(100, 8, 1, 1, 0, FMT_GF_BINARY, 0x70, 3, 4, 1, 0),
        100,
        "GF8 inf (exp=7) pays nothing"
    );
    // GF-T family: payable iff the offset is in range (< offset_max); an out-of-range offset mints 0.
    assert_eq!(
        settle_canonical(100, 16, 1, 1, 0, FMT_GFT, 40, 0, 0, 0, 80),
        116,
        "GF-T16 offset 40 < 80 pays 16"
    );
    assert_eq!(
        settle_canonical(100, 16, 1, 1, 0, FMT_GFT, 80, 0, 0, 0, 80),
        100,
        "GF-T16 offset == offset_max pays nothing"
    );
}
