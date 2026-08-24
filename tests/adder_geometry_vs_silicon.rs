//! adder_geometry_vs_silicon -- the SSOT<->silicon cross-check reaches the ADDER, not just the
//! multiplier. gft_add.v (GF-T16) and gft_add64.v (GF-T64) carry `parameter OFFSET_MAX`, `MANT_ONE`,
//! and `SIG_BITS` (the significand width = mant_bits + 1, the leading implicit 1). These must equal
//! the tri_gft_ladder SSOT: offset_max(Et) = 3^Et-1, mant_one = 2^mant_bits, sig_bits = mant_bits+1.
//! Together with ladder_geometry_vs_silicon (the multipliers), this pins that the WHOLE GF-T ALU --
//! mul AND add -- shares one rung geometry, so no operator can drift from the ladder on chip. Reads
//! the ACTUAL Verilog with include_str!.

const ADD16_V: &str = include_str!("../fpga/gft/gft_add.v");
const ADD64_V: &str = include_str!("../fpga/gft/gft_add64.v");

fn ssot_pow3(et: u32) -> u128 {
    (0..et).fold(1u128, |acc, _| acc * 3)
}
fn ssot_offset_max(et: u32) -> u128 {
    ssot_pow3(et) - 1
}
fn ssot_mant_one(mant_bits: u32) -> u128 {
    1u128 << mant_bits
}

fn verilog_param(src: &str, name: &str) -> u128 {
    for line in src.lines() {
        let t = line.trim();
        if t.starts_with("parameter") && t.contains(name) && t.contains('=') {
            let rhs = t.split('=').nth(1).expect("param has '='");
            if let Some(i) = rhs.find("'h") {
                let hex: String = rhs[i + 2..]
                    .chars()
                    .take_while(|c| c.is_ascii_hexdigit() || *c == '_')
                    .filter(|c| *c != '_')
                    .collect();
                return u128::from_str_radix(&hex, 16).expect("hex literal");
            }
            if let Some(i) = rhs.find("'d") {
                let dec: String = rhs[i + 2..]
                    .chars()
                    .take_while(|c| c.is_ascii_digit() || *c == '_')
                    .filter(|c| *c != '_')
                    .collect();
                return dec.parse().expect("decimal literal");
            }
            let dec: String = rhs
                .chars()
                .skip_while(|c| !c.is_ascii_digit())
                .take_while(|c| c.is_ascii_digit() || *c == '_')
                .filter(|c| *c != '_')
                .collect();
            return dec.parse().expect("bare decimal literal");
        }
    }
    panic!("parameter {name} not found");
}

#[test]
fn the_gf_t16_adder_geometry_matches_the_ssot_rung() {
    // GF-T16 is Et4, mant_bits 9; sig_bits = mant_bits + 1 = 10.
    assert_eq!(
        verilog_param(ADD16_V, "OFFSET_MAX"),
        ssot_offset_max(4),
        "GF-T16 offset_max == 3^4-1 = 80"
    );
    assert_eq!(
        verilog_param(ADD16_V, "MANT_ONE"),
        ssot_mant_one(9),
        "GF-T16 mant_one == 2^9 = 512"
    );
    assert_eq!(
        verilog_param(ADD16_V, "SIG_BITS"),
        10,
        "GF-T16 sig_bits = mant_bits + 1 = 10"
    );
}

#[test]
fn the_gf_t64_adder_geometry_matches_the_ssot_rung() {
    // GF-T64 is Et9, mant_bits 64; sig_bits = 65.
    assert_eq!(
        verilog_param(ADD64_V, "OFFSET_MAX"),
        ssot_offset_max(9),
        "GF-T64 offset_max == 3^9-1 = 19682"
    );
    assert_eq!(
        verilog_param(ADD64_V, "MANT_ONE"),
        ssot_mant_one(64),
        "GF-T64 mant_one == 2^64"
    );
    assert_eq!(
        verilog_param(ADD64_V, "SIG_BITS"),
        65,
        "GF-T64 sig_bits = 64 + 1 = 65"
    );
}

#[test]
fn sig_bits_is_exactly_mant_bits_plus_one_on_both_rungs() {
    // The significand is the mantissa plus the implicit leading 1, so its width is mant_bits + 1.
    // GF-T16 mant_bits 9 -> sig 10; GF-T64 mant_bits 64 -> sig 65.
    assert_eq!(verilog_param(ADD16_V, "SIG_BITS") as u32, 9 + 1);
    assert_eq!(verilog_param(ADD64_V, "SIG_BITS") as u32, 64 + 1);
    // and mant_one has exactly mant_bits below its set bit (2^mant_bits), so sig_bits = log2(mant_one)+1.
    assert_eq!(
        verilog_param(ADD16_V, "MANT_ONE"),
        1u128 << (verilog_param(ADD16_V, "SIG_BITS") - 1)
    );
    assert_eq!(
        verilog_param(ADD64_V, "MANT_ONE"),
        1u128 << (verilog_param(ADD64_V, "SIG_BITS") - 1)
    );
}

#[test]
fn the_adder_and_the_ssot_agree_that_offset_max_is_three_to_the_et_minus_one() {
    // The adder's ceiling is the ladder's special row, so a sum that saturates the exponent saturates
    // at the SAME value the validity gate (gfvalid) treats as the reserved special row.
    assert_eq!(verilog_param(ADD16_V, "OFFSET_MAX"), 80);
    assert_eq!(verilog_param(ADD64_V, "OFFSET_MAX"), 19682);
    assert_eq!(ssot_offset_max(4), 80);
    assert_eq!(ssot_offset_max(9), 19682);
}
