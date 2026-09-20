//! bond_collateralization_gate -- CI guard for the invariant that makes fraud unprofitable: the
//! posted bond must COVER the node's outstanding value-at-risk, scaled by the ladder rung. A fixed
//! bond is toothless once a node escrows more value than the bond -- a fraudster with bond=1 across
//! 1000 tasks loses ~nothing to a slash. specs/tri_compute_bond.t27 gates admission on
//! bond >= required_bond(outstanding, ratio), raised per rung, but only its bonded-lifecycle
//! functions (balance_after_resolve) had a CI twin -- the COVERAGE GATE itself (required_bond /
//! bond_covers / the rung-aware variants, with the u64-widened mulDiv that stops a u32 overflow)
//! had none. This transcribes them and pins the gate, the anti-fraud rejection, and the overflow safety.

const BOND_BPS_UNIT: u32 = 10000; // 100%
const GFT16_ET: u32 = 4;
const BOND_BPS_PER_TRIT: u32 = 500; // +5% collateral per exponent trit above GF-T16

/// Minimum bond for `outstanding` at `min_bps`, u64-widened then floor-divided (tri_compute_bond).
fn required_bond(outstanding: u32, min_bps: u32) -> u32 {
    let need = (outstanding as u64) * (min_bps as u64);
    (need / (BOND_BPS_UNIT as u64)) as u32
}

fn bond_covers(bond: u32, outstanding: u32, min_bps: u32) -> bool {
    bond >= required_bond(outstanding, min_bps)
}

/// A wider rung demands a higher ratio: +500 bps per exponent trit above GF-T16 (Et4).
fn rung_min_bps(min_bps: u32, gf_et: u32) -> u32 {
    if gf_et <= GFT16_ET {
        min_bps
    } else {
        min_bps + (gf_et - GFT16_ET) * BOND_BPS_PER_TRIT
    }
}

fn required_bond_rung(outstanding: u32, min_bps: u32, gf_et: u32) -> u32 {
    required_bond(outstanding, rung_min_bps(min_bps, gf_et))
}

fn bond_covers_rung(bond: u32, outstanding: u32, min_bps: u32, gf_et: u32) -> bool {
    bond >= required_bond_rung(outstanding, min_bps, gf_et)
}

#[test]
fn required_bond_scales_with_outstanding_and_ratio() {
    assert_eq!(required_bond(1000, 2000), 200, "20% of 1000");
    assert_eq!(
        required_bond(1000, BOND_BPS_UNIT),
        1000,
        "100% -> bond equals outstanding"
    );
    assert_eq!(
        required_bond(1000, 15000),
        1500,
        "150% -> over-collateralized"
    );
    assert_eq!(required_bond(0, 15000), 0, "no outstanding needs no bond");
}

#[test]
fn the_coverage_gate_rejects_an_undercollateralized_bond() {
    // The anti-fraud property: a bond below the required collateral does NOT cover.
    assert!(bond_covers(200, 1000, 2000), "200 covers 20% of 1000");
    assert!(
        !bond_covers(199, 1000, 2000),
        "199 is one short of the 200 required"
    );
    assert!(
        !bond_covers(1, 1000, 2000),
        "a nominal bond does NOT cover 1000 of risk"
    );
    assert!(
        bond_covers(1000, 1000, BOND_BPS_UNIT),
        "a full 100% bond covers"
    );
    assert!(
        bond_covers(0, 0, 20000),
        "a fresh node with no outstanding is covered by zero bond"
    );
}

#[test]
fn a_wider_rung_demands_more_collateral() {
    assert_eq!(
        rung_min_bps(2000, 4),
        2000,
        "GF-T16 (Et4) uses the base ratio"
    );
    assert_eq!(rung_min_bps(2000, 6), 3000, "GF-T32 (Et6) +2 trits -> +10%");
    assert_eq!(rung_min_bps(2000, 9), 4500, "GF-T64 (Et9) +5 trits -> +25%");
    assert_eq!(
        rung_min_bps(2000, 14),
        7000,
        "GF-T128 (Et14) +10 trits -> +50%"
    );
    assert_eq!(
        rung_min_bps(2000, 3),
        2000,
        "sub-flagship GF-T8 uses the base (never shrinks)"
    );
    assert_eq!(required_bond_rung(1000, 2000, 4), 200, "GF-T16 needs 200");
    assert_eq!(
        required_bond_rung(1000, 2000, 9),
        450,
        "GF-T64 needs 450 -- more collateral"
    );
    assert!(
        required_bond_rung(1000, 2000, 9) > required_bond_rung(1000, 2000, 4),
        "wider rung -> bigger bond"
    );
    // A bond sized for GF-T16 underfunds a GF-T64 result.
    assert!(bond_covers_rung(450, 1000, 2000, 9), "450 covers GF-T64");
    assert!(
        !bond_covers_rung(200, 1000, 2000, 9),
        "a GF-T16-sized bond underfunds GF-T64"
    );
}

#[test]
fn required_bond_is_monotone_in_rung_over_a_sweep() {
    // Higher rung must NEVER demand less collateral -- a fraudster cannot pick a wide rung to escape
    // a bigger bond. Sweep outstanding x base-ratio, assert non-decreasing across the ladder Ets.
    let ets = [3u32, 4, 6, 9, 14, 22];
    for &outstanding in &[0u32, 1000, 1_000_000] {
        for &base in &[2000u32, 10000] {
            let mut prev = 0u32;
            for &et in &ets {
                let r = required_bond_rung(outstanding, base, et);
                assert!(
                    r >= prev,
                    "rung {et} demanded less than a lower rung (o={outstanding} base={base})"
                );
                prev = r;
            }
        }
    }
}

#[test]
fn the_u64_widening_prevents_a_u32_overflow_at_scale() {
    // outstanding 1e6 * min_bps 20000 = 2e10 > 2^32. The u64 numerator floor-divides to 2e6 exactly;
    // a bare u32 product would wrap to 2_820_130_816 and yield a garbage 282_013 required bond --
    // which would let a huge outstanding risk pass with a tiny bond.
    assert_eq!(
        required_bond(1_000_000, 20000),
        2_000_000,
        "u64 mulDiv keeps it exact"
    );
    let bare_num = (1_000_000u32).wrapping_mul(20000); // 2e10 mod 2^32
    assert_eq!(
        bare_num / (BOND_BPS_UNIT),
        282_013,
        "the garbage required-bond the u64 widening prevents"
    );
    assert_ne!(
        required_bond(1_000_000, 20000),
        bare_num / BOND_BPS_UNIT,
        "exact != wrapped garbage"
    );
}
