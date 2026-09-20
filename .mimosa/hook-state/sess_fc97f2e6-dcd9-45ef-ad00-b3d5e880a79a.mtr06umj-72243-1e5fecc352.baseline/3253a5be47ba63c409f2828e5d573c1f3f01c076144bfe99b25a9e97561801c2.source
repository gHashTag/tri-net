//! gfvalid_finiteness -- CI guard for the GoldenFloat validity gate (specs/tri_compute_gfvalid.t27),
//! the layer that decides whether a GF result is a PAYABLE (finite, in-range) value -- it feeds
//! payable_flag / the settle mint gate (settle_mint_gate, #284). compute_ring_invariants covers only
//! the GF-T16 case; the multi-format binary finiteness (with the has_inf flag), the GF-T ladder
//! validity, the FAIL-CLOSED width-derived offset_max (a crafted width must NOT open the gate via a
//! u32 underflow), the range-vs-finiteness distinction, and the family dispatcher had no dedicated CI
//! twin. This transcribes those functions and pins them, including the anti-fail-open underflow guard.

fn is_finite_gf(result: u32, exp_bits: u32, mant_bits: u32) -> bool {
    let exp_mask = (1u32 << exp_bits) - 1;
    ((result >> mant_bits) & exp_mask) != exp_mask
}
fn is_finite_gf_h(result: u32, exp_bits: u32, mant_bits: u32, has_inf: u32) -> bool {
    if has_inf == 1 {
        is_finite_gf(result, exp_bits, mant_bits)
    } else {
        true // no special row -> every exponent is a normal value
    }
}
fn gft_pow3(exp_trits: u32) -> u32 {
    match exp_trits {
        2 => 9,
        3 => 27,
        4 => 81,
        5 => 243,
        6 => 729,
        7 => 2187,
        8 => 6561,
        9 => 19683,
        14 => 4782969,
        _ => 0,
    }
}
fn gft_offset_max(exp_trits: u32) -> u32 {
    gft_pow3(exp_trits) - 1
}
fn gft_exp_trits_for_width(width: u32) -> u32 {
    match width {
        4 => 2,
        8 => 3,
        16 => 4,
        32 => 6,
        64 => 9,
        128 => 14,
        _ => 0,
    }
}
fn gft_offset_max_for_width(width: u32) -> u32 {
    let et = gft_exp_trits_for_width(width);
    if et == 0 {
        0 // FAIL-CLOSED: not gft_offset_max(0) = gft_pow3(0)-1 = 0u32.wrapping_sub(1) = 0xFFFFFFFF
    } else {
        gft_offset_max(et)
    }
}
fn is_finite_gft_n(offset: u32, exp_trits: u32) -> bool {
    offset != gft_offset_max(exp_trits)
}
fn gft_offset_in_range(offset: u32, exp_trits: u32) -> bool {
    offset < gft_pow3(exp_trits)
}
fn is_valid_gft(offset: u32, exp_trits: u32) -> bool {
    offset < gft_pow3(exp_trits) && offset != gft_offset_max(exp_trits)
}
const FMT_GF_BINARY: u32 = 0;
const FMT_GFT16: u32 = 1;
fn is_finite_dispatch(
    fmt_family: u32,
    value: u32,
    exp_bits: u32,
    mant_bits: u32,
    has_inf: u32,
    exp_trits: u32,
) -> bool {
    if fmt_family == FMT_GFT16 {
        is_finite_gft_n(value, exp_trits)
    } else {
        is_finite_gf_h(value, exp_bits, mant_bits, has_inf)
    }
}

#[test]
fn binary_finiteness_detects_inf_nan_at_the_right_exponent_width() {
    // The all-ones exponent is inf/nan, at the format's own exp field width/position.
    assert!(is_finite_gf(0x4200, 6, 9), "GF16 4.0 finite");
    assert!(!is_finite_gf(0x7E00, 6, 9), "GF16 +inf");
    assert!(!is_finite_gf(0x7E01, 6, 9), "GF16 NaN");
    assert!(is_finite_gf(0x20, 3, 4), "GF8 finite (exp 2)");
    assert!(!is_finite_gf(0x70, 3, 4), "GF8 exp==7 all-ones");
    assert!(is_finite_gf(0x1, 1, 2), "GF4 finite (exp 0)");
    assert!(!is_finite_gf(0x4, 1, 2), "GF4 special (exp 1)");
    assert!(!is_finite_gf(0x1F00, 5, 8), "GF14 +inf (exp 31)");
}

#[test]
fn the_has_inf_flag_makes_a_max_exponent_normal_where_no_special_row_exists() {
    // GF16 reserves the all-ones exponent for inf/nan; GF8/GF4 use EVERY exponent as a value, so a
    // hardcoded GF16 rule would WRONGLY reject a valid max-exp GF8 result and pay zero for real work.
    assert!(
        !is_finite_gf_h(0x7E00, 6, 9, 1),
        "GF16 inf rejected (has_inf)"
    );
    assert!(is_finite_gf_h(0x4200, 6, 9, 1), "GF16 finite accepted");
    assert!(
        is_finite_gf_h(0x70, 3, 4, 0),
        "GF8 max-exp is a NORMAL value (no special row)"
    );
    assert!(
        !is_finite_gf_h(0x70, 3, 4, 1),
        "with has_inf it would (wrongly) reject"
    );
}

#[test]
fn the_gft_ladder_special_row_is_three_to_the_et_minus_one_per_rung() {
    assert_eq!(gft_offset_max(2), 8, "GF-T4 = 3^2-1");
    assert_eq!(gft_offset_max(3), 26, "GF-T8 = 3^3-1");
    assert_eq!(gft_offset_max(4), 80, "GF-T16 = 3^4-1");
    assert_eq!(
        gft_offset_max(6),
        728,
        "GF-T32 = 3^6-1 (Et6, golden rule -- NOT log2=5)"
    );
    assert_eq!(gft_offset_max(9), 19682, "GF-T64 = 3^9-1");
    assert!(is_finite_gft_n(7, 2), "GF-T4 offset 7 finite");
    assert!(!is_finite_gft_n(8, 2), "GF-T4 offset 8 is the special row");
    assert!(
        is_finite_gft_n(242, 6) && !is_finite_gft_n(728, 6),
        "GF-T32: 242 normal, 728 special"
    );
}

#[test]
fn the_width_derived_offset_max_is_fail_closed_never_fail_open() {
    // A settlement pins the special row to the ASSIGNMENT-bound width, so an executor cannot claim a
    // huge ceiling. Every known rung maps to its canonical offset_max...
    assert_eq!(gft_offset_max_for_width(16), 80);
    assert_eq!(gft_offset_max_for_width(32), 728);
    assert_eq!(gft_offset_max_for_width(64), 19682);
    assert_eq!(gft_offset_max_for_width(128), 4782968);
    assert_eq!(
        gft_offset_max_for_width(16),
        gft_offset_max(4),
        "width 16 -> Et 4"
    );
    // ...and an unknown/crafted width FAILS CLOSED at 0 (nothing is < 0, so nothing is payable),
    // NEVER the gft_pow3(0)-1 = 0u32 - 1 = 0xFFFFFFFF underflow which would be fail-OPEN (everything
    // payable). This is the security-critical branch: a garbage width must not open the gate.
    assert_eq!(gft_offset_max_for_width(0), 0, "width 0 -> fail-closed 0");
    assert_eq!(
        gft_offset_max_for_width(7),
        0,
        "off-ladder width -> fail-closed 0"
    );
    assert_eq!(
        gft_offset_max_for_width(u32::MAX),
        0,
        "garbage width -> fail-closed 0, no underflow"
    );
    assert_ne!(
        gft_offset_max_for_width(0),
        0u32.wrapping_sub(1),
        "NOT the fail-open 0xFFFFFFFF"
    );
}

#[test]
fn validity_is_range_and_finiteness_together() {
    // An out-of-range offset (>= 3^Et) is classed FINITE by is_finite_gft_n alone (offset != max),
    // so the range gate must catch it first; is_valid_gft requires BOTH.
    assert!(
        gft_offset_in_range(80, 4) && !gft_offset_in_range(81, 4),
        "80 in range, 81 (==3^4) out"
    );
    assert!(
        is_finite_gft_n(81, 4),
        "is_finite ALONE wrongly calls out-of-range 81 finite"
    );
    assert!(
        !is_valid_gft(81, 4),
        "but is_valid_gft rejects it (out of range)"
    );
    assert!(
        !is_valid_gft(80, 4),
        "the special row 80 is in range but not finite -> not payable"
    );
    assert!(
        is_valid_gft(79, 4),
        "offset 79 (just below the special row) is payable"
    );
    assert!(
        is_valid_gft(7, 2) && !is_valid_gft(8, 2) && !is_valid_gft(9, 2),
        "GF-T4: 7 payable, 8 special, 9 out of range"
    );
}

#[test]
fn the_dispatcher_routes_by_family_and_agrees_with_the_underlying_checks() {
    // Routing a GF-T offset by the binary all-ones rule (or vice versa) would misclassify; the
    // dispatcher picks the right check per family.
    assert_eq!(
        is_finite_dispatch(FMT_GF_BINARY, 0x4200, 6, 9, 1, 0),
        is_finite_gf_h(0x4200, 6, 9, 1)
    );
    assert!(
        !is_finite_dispatch(FMT_GF_BINARY, 0x7E00, 6, 9, 1, 0),
        "GF16 inf via dispatch"
    );
    assert!(
        is_finite_dispatch(FMT_GF_BINARY, 0x70, 3, 4, 0, 0),
        "GF8 max-exp normal via dispatch"
    );
    assert_eq!(
        is_finite_dispatch(FMT_GFT16, 40, 0, 0, 0, 4),
        is_finite_gft_n(40, 4),
        "GF-T16 finite via dispatch"
    );
    assert!(
        !is_finite_dispatch(FMT_GFT16, 80, 0, 0, 0, 4),
        "GF-T16 special row via dispatch"
    );
    assert!(
        !is_finite_dispatch(FMT_GFT16, 8, 0, 0, 0, 2),
        "GF-T4 special row 8 via dispatch"
    );
}
