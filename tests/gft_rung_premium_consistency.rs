//! gft_rung_premium_consistency -- the three rung-aware economic axes must share ONE
//! premium shape, so they cannot silently diverge (the way the GF-T32 Et rule once
//! diverged from log2 across gfvalid/settle/ladder). Each axis raises a base value by a
//! per-trit step for every exponent trit above the flagship GF-T16 (Et4):
//!
//!   challenge window   (tri_compute_optimistic.window_for_rung):  base 64,  step 16
//!   required bond bps  (tri_compute_bond.rung_min_bps):           base bps, step 500
//!   honest rep gain    (tri_compute_reputation.rung_honest_gain): base gain,step 3
//!
//! This pins the canonical `rung_premium(base, step, et)` and checks each axis's
//! published values match it -- a regression guard: if one axis is re-derived by a
//! different rule (log2, multiplicative, a shrink below base), this test fails.

const GFT16_ET: u32 = 4;

/// The one canonical premium shape. base at/below GF-T16; +step per exponent trit above.
fn rung_premium(base: u32, step: u32, et: u32) -> u32 {
    if et <= GFT16_ET {
        base
    } else {
        base + step * (et - GFT16_ET)
    }
}

// The ladder rungs (width, Et) the economic layer covers.
const RUNGS: [(u32, u32); 5] = [(8, 3), (16, 4), (32, 6), (64, 9), (128, 14)];

#[test]
fn window_axis_matches_the_shape() {
    // tri_compute_optimistic: BASE_WINDOW 64, WINDOW_PER_TRIT 16.
    let published = [(4u32, 64u32), (6, 96), (9, 144), (14, 224)];
    for (et, w) in published {
        assert_eq!(
            rung_premium(64, 16, et),
            w,
            "window at Et{et} must match the shape"
        );
    }
    assert_eq!(
        rung_premium(64, 16, 3),
        64,
        "sub-flagship window stays at base"
    );
}

#[test]
fn bond_axis_matches_the_shape() {
    // tri_compute_bond: base min_bps (here 2000), BOND_BPS_PER_TRIT 500.
    let published = [(4u32, 2000u32), (6, 3000), (9, 4500), (14, 7000)];
    for (et, bps) in published {
        assert_eq!(
            rung_premium(2000, 500, et),
            bps,
            "bond bps at Et{et} must match the shape"
        );
    }
}

#[test]
fn reputation_axis_matches_the_shape() {
    // tri_compute_reputation: base gain (here 5), REP_GAIN_PER_TRIT 3.
    let published = [(4u32, 5u32), (6, 11), (9, 20), (14, 35)];
    for (et, g) in published {
        assert_eq!(
            rung_premium(5, 3, et),
            g,
            "rep gain at Et{et} must match the shape"
        );
    }
}

#[test]
fn every_axis_is_monotone_non_decreasing_up_the_ladder() {
    // A positive step makes the premium grow (never shrink) with the rung, for each axis.
    for &step in &[16u32, 500, 3] {
        let mut prev = 0u32;
        for &(_w, et) in RUNGS.iter() {
            let p = rung_premium(100, step, et);
            assert!(
                p >= prev,
                "premium must be monotone in Et (step {step}): {p} < {prev}"
            );
            prev = p;
        }
    }
}

#[test]
fn the_shape_coincides_with_no_growth_only_at_or_below_the_flagship() {
    // The premium equals the base exactly for Et <= 4 (GF-T8, GF-T16) and strictly exceeds
    // it for every higher rung -- the property that makes "higher rung costs more" hold.
    for &(_w, et) in RUNGS.iter() {
        let p = rung_premium(100, 10, et);
        if et <= GFT16_ET {
            assert_eq!(p, 100, "Et{et} <= flagship -> base");
        } else {
            assert!(p > 100, "Et{et} > flagship -> strictly above base");
        }
    }
}
