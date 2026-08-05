//! trinet_rung_verify -- rung-aware verification: pick the GF-T geometry by WIDTH.
//!
//! A receipt names its GF width; the verifier looks up the rung's (bias, offset_max,
//! mantissa scale) via tri_gft_ladder and recomputes the multiply with THOSE
//! parameters (tri_gft_arith.verify_gft_mul_full_p). So a GF-T8 result is checked as
//! GF-T8, not GF-T16 -- and verifying it with the wrong rung's geometry FAILS.
//! (GF-T32 is not covered: its 25-bit mantissa needs u64, blocked by a t27c defect.)
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_gft_ladder.rs"] mod lad;
#[path = "../../gen/rust/tri_gft_arith.rs"] mod gfa;

/// Verify a claimed GF-T multiply result for a receipt of the given WIDTH.
fn verify_mul_for_width(width: u32, oa: u32, ma: u32, ob: u32, mb: u32, claimed_off: u32, claimed_mant: u32) -> bool {
    let et = lad::width_to_et(width);
    let bias = lad::gft_bias(et);
    let omax = lad::gft_offset_max(et);
    let mant_one = lad::gft_mant_one(et);
    gfa::verify_gft_mul_full_p(oa, ma, ob, mb, claimed_off, claimed_mant, bias, omax, mant_one)
}

fn main() {
    // Honest per-rung multiplies (phi^k results). GF-T8: 1.5*1.5 -> exp 14, mant 2
    // (bias 13, mant_one 16); GF-T16: 1.5*1.5 -> exp 43, mant 64; GF-T4: 1.5*1.5 -> exp 5, mant 0.
    assert!(verify_mul_for_width(8, 13, 8, 13, 8, 14, 2), "GF-T8 verified as GF-T8");
    assert!(verify_mul_for_width(16, 41, 256, 41, 256, 43, 64), "GF-T16 verified as GF-T16");
    assert!(verify_mul_for_width(4, 4, 1, 4, 1, 5, 0), "GF-T4 verified as GF-T4");

    // Wrong rung: the SAME GF-T8 operands/result checked with GF-T16's geometry fails
    // (GF-T16 bias 40 gives a different exponent) -- the width must select the rung.
    let wrong = gfa::verify_gft_mul_full_p(13, 8, 13, 8, 14, 2, lad::gft_bias(lad::GFT16_ET), lad::gft_offset_max(lad::GFT16_ET), lad::gft_mant_one(lad::GFT16_ET));
    assert!(!wrong, "GF-T8 result checked with GF-T16 geometry is rejected");

    println!("rung-aware verification (width -> geometry):");
    println!("  GF-T8  1.5*1.5 -> (exp 14, mant 2) accepted (bias {}, mant_one {})", lad::gft_bias(lad::width_to_et(8)), lad::gft_mant_one(lad::width_to_et(8)));
    println!("  GF-T16 1.5*1.5 -> (exp 43, mant 64) accepted (bias {})", lad::gft_bias(lad::width_to_et(16)));
    println!("  GF-T4  1.5*1.5 -> (exp 5, mant 0) accepted (bias {})", lad::gft_bias(lad::width_to_et(4)));
    println!("  GF-T8 result checked with GF-T16 geometry -> rejected (wrong rung)");
    println!("OK: a receipt's GF width selects the rung geometry; each rung verifies with its own bias/mantissa scale");
}
