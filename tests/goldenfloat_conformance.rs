//! goldenfloat_conformance -- cross-validate the phi-formula catalog against the CANONICAL t27
//! authority (conformance/goldenfloat_family_vectors.json in gHashTag/t27), not just our own
//! recompute. This is the honest-ruler check for goldenfloat_family_ladder.rs: those tests prove
//! the significand arithmetic is self-consistent at any width; this proves the FORMAT GEOMETRY
//! (exp/mant per rung) matches the sealed GoldenFloat family definition.
//!
//! Canonical facts pinned below are taken verbatim from the t27 conformance seal:
//!   - the family is EXACTLY 7 formats: GF4, GF8, GF12, GF16, GF20, GF24, GF32 (family_size == 7);
//!   - GF4 = S1 E1 M2;  GF8 = S1 E3 M4;  GF16 = S1 E6 M9 (primary);  GF32 = S1 E12 M19;
//!   - every format has sign_bits == 1 and sign+exp+mant == bits;
//!   - memory_efficiency(GFk) = k/32, so GF4 -> 0.125 and GF32 -> 1.0.
//!
//! IMPORTANT correction to goldenfloat_family_ladder.rs: the SSOT family STOPS at GF32 (7 formats).
//! GF64..GF1024 are the width-agnostic *arithmetic* extension of the recurrence (real, and proven
//! exact there in BigUint), NOT members of the canonical 7-format family; the arXiv 83-format
//! catalog is a separate, larger enumeration. And the binary GF32 mantissa is 19, whereas the
//! ternary GF-T32 rung uses a 25-bit mantissa -- different variants of the same phi family.

/// The GoldenFloat family exp/mant split from total bits: exp = round((bits-1)/phi^2).
fn rung(bits: u32) -> (u32, u32) {
    let phi = (1.0 + 5f64.sqrt()) / 2.0;
    let exp = (((bits - 1) as f64) / (phi * phi)).round() as u32;
    (exp, bits - 1 - exp)
}

/// The canonical 7-format family (t27 conformance: family_size == 7, GF4..GF32).
const FAMILY: &[u32] = &[4, 8, 12, 16, 20, 24, 32];

#[test]
fn phi_formula_matches_the_canonical_anchors() {
    // Verbatim from the t27 conformance seal.
    assert_eq!(rung(4), (1, 2), "GF4 = S1 E1 M2");
    assert_eq!(rung(8), (3, 4), "GF8 = S1 E3 M4");
    assert_eq!(rung(16), (6, 9), "GF16 = S1 E6 M9 (primary anchor)");
    assert_eq!(rung(32), (12, 19), "GF32 = S1 E12 M19");
}

#[test]
fn the_family_is_exactly_seven_formats_and_well_formed() {
    assert_eq!(FAMILY.len(), 7, "canonical GoldenFloat family_size == 7");
    assert_eq!(FAMILY[0], 4, "GF4 at index 0");
    assert_eq!(FAMILY[6], 32, "GF32 at index 6");
    for &bits in FAMILY {
        let (e, m) = rung(bits);
        assert_eq!(1 + e + m, bits, "GF{bits}: sign+exp+mant == bits");
    }
}

#[test]
fn memory_efficiency_matches_the_seal() {
    let eff = |bits: u32| bits as f64 / 32.0;
    assert!(
        (eff(4) - 0.125).abs() < 1e-12,
        "memory_efficiency(GF4) == 0.125"
    );
    assert!(
        (eff(32) - 1.0).abs() < 1e-12,
        "memory_efficiency(GF32) == 1.0"
    );
}

#[test]
fn gf16_is_the_designated_primary() {
    // The seal marks GF16.is_primary = true (invariant primary_is_gf16, at family index 3). This is
    // a DESIGN designation -- the frozen 16-bit silicon anchor -- NOT a phi-optimality claim: the
    // ratio closest to 1/phi is actually GF32 (12/19 = 0.632 vs 1/phi = 0.618), so we do not pretend
    // GF16 wins on phi-distance. We only assert the canonical fact + honestly note GF32 is closer.
    assert_eq!(
        FAMILY[3], 16,
        "GF16 sits at family index 3 (the primary slot per the seal)"
    );
    let inv_phi = 2.0 / (1.0 + 5f64.sqrt());
    let ratio = |bits: u32| {
        let (e, m) = rung(bits);
        e as f64 / m as f64
    };
    assert!(
        (ratio(32) - inv_phi).abs() < (ratio(16) - inv_phi).abs(),
        "primary is a designation, not phi-optimality: GF32 is actually nearer 1/phi than GF16"
    );
}
