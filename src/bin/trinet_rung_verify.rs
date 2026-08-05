//! trinet_rung_verify -- rung-aware verification: pick the GF-T geometry by WIDTH.
//!
//! A receipt names its GF width; the verifier looks up the rung's (bias, offset_max,
//! mantissa scale) via tri_gft_ladder and recomputes multiply / add / subtract with
//! THOSE parameters (tri_gft_arith / tri_gft_add / tri_gft_sub). So a GF-T8 result is
//! checked as GF-T8, not GF-T16 -- verifying it with the wrong rung's geometry FAILS.
//! GF-T32 (25-bit mantissa, offsets to 728) overflows u32, so its multiply and subtract
//! run the u64 path (verify_gft_mul_full_u64 / verify_gft_sub_u64) -- same rung look-up,
//! u64 scale; add stays u32-safe via verify_gft_add_p. All four rungs x mul/add/sub.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_gft_ladder.rs"] mod lad;
#[path = "../../gen/rust/tri_gft_arith.rs"] mod gfa;
#[path = "../../gen/rust/tri_gft_add.rs"] mod gadd;
#[path = "../../gen/rust/tri_gft_sub.rs"] mod gsub;

/// Verify a claimed GF-T multiply result for a receipt of the given WIDTH.
fn verify_mul_for_width(width: u32, oa: u32, ma: u32, ob: u32, mb: u32, claimed_off: u32, claimed_mant: u32) -> bool {
    let et = lad::width_to_et(width);
    let bias = lad::gft_bias(et);
    let omax = lad::gft_offset_max(et);
    let mant_one = lad::gft_mant_one(et);
    gfa::verify_gft_mul_full_p(oa, ma, ob, mb, claimed_off, claimed_mant, bias, omax, mant_one)
}

/// GF-T32 needs u64: the 25-bit mantissa and offsets up to 728 overflow the u32 path.
/// Same rung look-up (width -> geometry), verified at u64 scale.
fn verify_mul_for_width_u64(width: u32, oa: u32, ma: u64, ob: u32, mb: u64, claimed_off: u32, claimed_mant: u32) -> bool {
    let et = lad::width_to_et(width);
    let bias = lad::gft_bias(et);
    let omax = lad::gft_offset_max(et);
    let mant_one = lad::gft_mant_one(et) as u64;
    gfa::verify_gft_mul_full_u64(oa, ma, ob, mb, claimed_off, claimed_mant, bias, omax, mant_one)
}

/// Verify a same-sign ADD for a receipt of the given WIDTH (u32-safe across all rungs).
fn verify_add_for_width(width: u32, oa: u32, ma: u32, ob: u32, mb: u32, claimed_off: u32, claimed_mant: u32) -> bool {
    let et = lad::width_to_et(width);
    let omax = lad::gft_offset_max(et);
    let mant_one = lad::gft_mant_one(et);
    let sig_bits = lad::gft_mant_bits(et) + 1;
    gadd::verify_gft_add_p(oa, ob, ma, mb, claimed_off, claimed_mant, omax, mant_one, sig_bits)
}

/// Verify a different-sign SUB for GF-T4/8/16 (u32 path).
fn verify_sub_for_width(width: u32, oa: u32, ma: u32, ob: u32, mb: u32, claimed_off: u32, claimed_mant: u32) -> bool {
    let et = lad::width_to_et(width);
    let mant_one = lad::gft_mant_one(et);
    let mant_bits = lad::gft_mant_bits(et);
    gsub::verify_gft_sub_p(oa, ob, ma, mb, claimed_off, claimed_mant, mant_one, mant_bits)
}

/// Verify a different-sign SUB for GF-T32 (u64 path; ALIGN_CAP_U64 = 38).
fn verify_sub_for_width_u64(width: u32, oa: u32, ma: u64, ob: u32, mb: u64, claimed_off: u32, claimed_mant: u32) -> bool {
    let et = lad::width_to_et(width);
    let mant_one = lad::gft_mant_one(et) as u64;
    let mant_bits = lad::gft_mant_bits(et);
    gsub::verify_gft_sub_u64(oa, ob, ma, mb, claimed_off, claimed_mant, mant_one, mant_bits, 38)
}

fn main() {
    // Honest per-rung multiplies (phi^k results). GF-T8: 1.5*1.5 -> exp 14, mant 2
    // (bias 13, mant_one 16); GF-T16: 1.5*1.5 -> exp 43, mant 64; GF-T4: 1.5*1.5 -> exp 5, mant 0.
    assert!(verify_mul_for_width(8, 13, 8, 13, 8, 14, 2), "GF-T8 verified as GF-T8");
    assert!(verify_mul_for_width(16, 41, 256, 41, 256, 43, 64), "GF-T16 verified as GF-T16");
    assert!(verify_mul_for_width(4, 4, 1, 4, 1, 5, 0), "GF-T4 verified as GF-T4");

    // GF-T32 (u64 path): 1.5*1.5 -> exp 365, mant 2^22. Operands off 364 (exp 0),
    // mant field 2^24 (value 1.5, mant_one 2^25). The wrong exponent is rejected.
    assert!(verify_mul_for_width_u64(32, 364, 16777216, 364, 16777216, 365, 4194304), "GF-T32 verified as GF-T32 (u64)");
    assert!(!verify_mul_for_width_u64(32, 364, 16777216, 364, 16777216, 364, 4194304), "GF-T32 result with the wrong exponent is rejected");

    // Same-sign ADD per rung: 1.0 + 1.0 = 2.0 (operands at exp 0 -> off = bias, M = 0;
    // result 2.0 = (1+0)*2^1 -> off = bias+1, M = 0). Verified under each rung's scale.
    assert!(verify_add_for_width(4, 4, 0, 4, 0, 5, 0), "GF-T4 add 1+1=2");
    assert!(verify_add_for_width(8, 13, 0, 13, 0, 14, 0), "GF-T8 add 1+1=2");
    assert!(verify_add_for_width(16, 40, 0, 40, 0, 41, 0), "GF-T16 add 1+1=2");
    assert!(verify_add_for_width(32, 364, 0, 364, 0, 365, 0), "GF-T32 add 1+1=2 (u32-safe _p)");
    assert!(!verify_add_for_width(16, 40, 0, 40, 0, 40, 0), "GF-T16 add with the wrong exponent is rejected");

    // Different-sign SUB per rung: 2.0 - 1.0 = 1.0 (a at off bias+1, b at off bias;
    // result 1.0 -> off = bias, M = 0). GF-T32 runs the u64 path.
    assert!(verify_sub_for_width(4, 5, 0, 4, 0, 4, 0), "GF-T4 sub 2-1=1");
    assert!(verify_sub_for_width(8, 14, 0, 13, 0, 13, 0), "GF-T8 sub 2-1=1");
    assert!(verify_sub_for_width(16, 41, 0, 40, 0, 40, 0), "GF-T16 sub 2-1=1");
    assert!(verify_sub_for_width_u64(32, 365, 0, 364, 0, 364, 0), "GF-T32 sub 2-1=1 (u64)");
    assert!(!verify_sub_for_width(16, 41, 0, 40, 0, 41, 0), "GF-T16 sub with the wrong exponent is rejected");

    // Wrong rung: the SAME GF-T8 operands/result checked with GF-T16's geometry fails
    // (GF-T16 bias 40 gives a different exponent) -- the width must select the rung.
    let wrong = gfa::verify_gft_mul_full_p(13, 8, 13, 8, 14, 2, lad::gft_bias(lad::GFT16_ET), lad::gft_offset_max(lad::GFT16_ET), lad::gft_mant_one(lad::GFT16_ET));
    assert!(!wrong, "GF-T8 result checked with GF-T16 geometry is rejected");

    println!("rung-aware verification (width -> geometry):");
    println!("  GF-T8  1.5*1.5 -> (exp 14, mant 2) accepted (bias {}, mant_one {})", lad::gft_bias(lad::width_to_et(8)), lad::gft_mant_one(lad::width_to_et(8)));
    println!("  GF-T16 1.5*1.5 -> (exp 43, mant 64) accepted (bias {})", lad::gft_bias(lad::width_to_et(16)));
    println!("  GF-T4  1.5*1.5 -> (exp 5, mant 0) accepted (bias {})", lad::gft_bias(lad::width_to_et(4)));
    println!("  GF-T32 1.5*1.5 -> (exp 365, mant 2^22) accepted via u64 (bias {}, mant_one {})", lad::gft_bias(lad::width_to_et(32)), lad::gft_mant_one(lad::width_to_et(32)) as u64);
    println!("  add 1+1=2 and sub 2-1=1 verified for GF-T4/8/16/32 under each rung's scale");
    println!("  GF-T8 result checked with GF-T16 geometry -> rejected (wrong rung)");
    println!("OK: a receipt's GF width selects the rung geometry; each rung verifies with its own bias/mantissa scale");
}
