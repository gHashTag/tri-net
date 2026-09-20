//! challenge_rung_window -- pin the rung-aware challenge window to the optimistic layer's
//! window ladder. tri_challenge mirrors tri_compute_optimistic's constants (base window,
//! per-trit growth, flagship Et) because t27 modules do not import each other; a mirrored
//! constant is a drift risk, so this guard (a) parses BOTH .t27 specs with include_str! and
//! asserts the constants are literally equal, and (b) transcribes both window functions and
//! asserts rung-aware admissibility equals the open-window verdict at EVERY epoch across the
//! ladder -- the same seam-pinning as challenge_lifecycle_e2e, lifted to all rungs.

const CH_SPEC: &str = include_str!("../specs/tri_challenge.t27");
const OPT_SPEC: &str = include_str!("../specs/tri_compute_optimistic.t27");

/// Extract `const NAME: u32 = <dec>;` from a .t27 spec source.
fn spec_const(src: &str, name: &str) -> u128 {
    for line in src.lines() {
        let t = line.trim();
        if t.starts_with("const") && t.contains(name) && t.contains('=') {
            let rhs = t.split('=').nth(1).expect("const has '='");
            let dec: String = rhs
                .chars()
                .skip_while(|c| !c.is_ascii_digit())
                .take_while(|c| c.is_ascii_digit())
                .collect();
            return dec.parse().expect("spec const decimal");
        }
    }
    panic!("const {name} not found in spec");
}

// ---- transcriptions (post-parity: one set of constants) ----
const GFT16_ET: u32 = 4;
const BASE_WINDOW: u32 = 64;
const WINDOW_PER_TRIT: u32 = 16;

fn window_for_rung(gf_et: u32) -> u32 {
    if gf_et <= GFT16_ET {
        BASE_WINDOW
    } else {
        BASE_WINDOW + (gf_et - GFT16_ET) * WINDOW_PER_TRIT
    }
}
fn window_open(now_epoch: u32, settled_at: u32, window: u32) -> bool {
    now_epoch < (settled_at + window)
}
fn challenge_admissible(now_epoch: u32, receipt_epoch: u32, window: u32) -> bool {
    if now_epoch < receipt_epoch {
        return false;
    }
    (now_epoch - receipt_epoch) < window
}
fn challenge_admissible_rung(now_epoch: u32, receipt_epoch: u32, gf_et: u32) -> bool {
    challenge_admissible(now_epoch, receipt_epoch, window_for_rung(gf_et))
}
fn window_open_rung(now_epoch: u32, settled_at: u32, gf_et: u32) -> bool {
    window_open(now_epoch, settled_at, window_for_rung(gf_et))
}

#[test]
fn the_mirrored_window_constants_are_literally_equal_in_both_specs() {
    // tri_challenge's CH_* mirror tri_compute_optimistic's ladder; if either spec
    // retunes its window without the other, this fails before any behavior can drift.
    assert_eq!(
        spec_const(CH_SPEC, "CH_GFT16_ET"),
        spec_const(OPT_SPEC, "GFT16_ET"),
        "flagship Et"
    );
    assert_eq!(
        spec_const(CH_SPEC, "CH_BASE_WINDOW"),
        spec_const(OPT_SPEC, "BASE_WINDOW"),
        "base window"
    );
    assert_eq!(
        spec_const(CH_SPEC, "CH_WINDOW_PER_TRIT"),
        spec_const(OPT_SPEC, "WINDOW_PER_TRIT"),
        "per-trit growth"
    );
    // And the transcription above matches the specs it guards.
    assert_eq!(u128::from(GFT16_ET), spec_const(OPT_SPEC, "GFT16_ET"));
    assert_eq!(u128::from(BASE_WINDOW), spec_const(OPT_SPEC, "BASE_WINDOW"));
    assert_eq!(
        u128::from(WINDOW_PER_TRIT),
        spec_const(OPT_SPEC, "WINDOW_PER_TRIT")
    );
}

#[test]
fn rung_admissibility_equals_the_open_window_at_every_epoch_on_every_rung() {
    let settled = 1000u32;
    for et in 2..=10u32 {
        let w = window_for_rung(et);
        for now in (settled - 1)..(settled + w + 3) {
            assert_eq!(
                challenge_admissible_rung(now, settled, et),
                window_open_rung(now, settled, et) && now >= settled,
                "one edge on rung Et{et} at epoch {now}"
            );
        }
    }
}

#[test]
fn a_wide_rung_outlives_the_flagship_window_by_exactly_its_extra_trits() {
    let settled = 1000u32;
    // GF-T64 (Et9) earns (9-4)*16 = 80 extra epochs over the flagship.
    assert_eq!(window_for_rung(9) - window_for_rung(4), 80);
    let flagship_final = settled + window_for_rung(4);
    assert!(
        !challenge_admissible_rung(flagship_final, settled, 4),
        "flagship is final"
    );
    assert!(
        challenge_admissible_rung(flagship_final, settled, 9),
        "the wide rung is still challengeable at that epoch"
    );
    assert!(
        !challenge_admissible_rung(settled + window_for_rung(9), settled, 9),
        "and closes exactly at its own finalization epoch"
    );
}

#[test]
fn the_window_ladder_is_monotone_and_floored_at_the_base() {
    let mut prev = 0u32;
    for et in 0..=12u32 {
        let w = window_for_rung(et);
        assert!(w >= BASE_WINDOW, "never below the base (Et{et})");
        assert!(w >= prev, "monotone in Et (Et{et})");
        prev = w;
    }
}
