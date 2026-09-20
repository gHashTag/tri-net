//! ladder_geometry_vs_silicon -- extend the SSOT<->silicon cross-check (ladder_bias_vs_silicon, which
//! pinned BIAS) to the rest of a rung's MULTIPLIER geometry: OFFSET_MAX and MANT_ONE. tri_gft_ladder
//! is the single source of truth -- offset_max(Et) = 3^Et-1, mant_one = 2^mant_bits(Et) -- and the
//! synthesizable gft_mul32.v / gft_mul64.v carry those as `parameter OFFSET_MAX` / `parameter
//! MANT_ONE`. If the hardware and the SSOT ever disagree on the special-row ceiling or the mantissa
//! scale, a result would be classified / normalized differently in Rust than on chip. Reads the
//! ACTUAL Verilog with include_str!, extracts the parameters (decimal or underscored hex, up to 128
//! bits), and asserts each equals the SSOT formula -- so the whole multiplier geometry is one table.

const MUL32_V: &str = include_str!("../fpga/gft/gft_mul32.v");
const MUL64_V: &str = include_str!("../fpga/gft/gft_mul64.v");

fn ssot_pow3(et: u32) -> u128 {
    (0..et).fold(1u128, |acc, _| acc * 3)
}
fn ssot_offset_max(et: u32) -> u128 {
    ssot_pow3(et) - 1
}
fn ssot_mant_one(mant_bits: u32) -> u128 {
    1u128 << mant_bits
}

/// Extract `parameter [..] NAME = <literal>` as a u128. Handles a bare decimal and a Verilog sized
/// literal `<w>'d<dec>` / `<w>'h<hex>` (underscores in the digits are ignored).
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
fn the_param_extractor_reads_decimal_and_underscored_hex_literals() {
    assert_eq!(
        verilog_param(MUL32_V, "OFFSET_MAX"),
        728,
        "gft_mul32 OFFSET_MAX = 728 (decimal)"
    );
    assert_eq!(
        verilog_param(MUL32_V, "MANT_ONE"),
        33_554_432,
        "gft_mul32 MANT_ONE = 64'd33554432 = 2^25"
    );
    assert_eq!(
        verilog_param(MUL64_V, "MANT_ONE"),
        1u128 << 64,
        "gft_mul64 MANT_ONE = 128'h1_0000_..._0000 = 2^64"
    );
}

#[test]
fn the_gf_t32_multiplier_geometry_matches_the_ssot_rung() {
    // GF-T32 is Et6, mant_bits 25 (the ratified ladder).
    assert_eq!(
        verilog_param(MUL32_V, "OFFSET_MAX"),
        ssot_offset_max(6),
        "GF-T32 offset_max == 3^6-1 = 728"
    );
    assert_eq!(
        verilog_param(MUL32_V, "MANT_ONE"),
        ssot_mant_one(25),
        "GF-T32 mant_one == 2^25"
    );
    assert_eq!(
        ssot_offset_max(6) / 2,
        364,
        "bias = offset_max/2 = 364 (the silicon BIAS)"
    );
}

#[test]
fn the_gf_t64_multiplier_geometry_matches_the_ssot_rung() {
    // GF-T64 is Et9, mant_bits 64.
    assert_eq!(
        verilog_param(MUL64_V, "OFFSET_MAX"),
        ssot_offset_max(9),
        "GF-T64 offset_max == 3^9-1 = 19682"
    );
    assert_eq!(
        verilog_param(MUL64_V, "MANT_ONE"),
        ssot_mant_one(64),
        "GF-T64 mant_one == 2^64"
    );
    assert_eq!(ssot_offset_max(9) / 2, 9841, "bias = offset_max/2 = 9841");
}

#[test]
fn the_ssot_geometry_is_internally_consistent_across_the_rungs() {
    // offset_max = 3^Et-1 is even, so bias = offset_max/2 is exact (the balanced-ternary center).
    for &et in &[2u32, 3, 4, 6, 9] {
        assert_eq!(
            ssot_offset_max(et) % 2,
            0,
            "3^Et-1 is even -> bias is a clean center at Et{et}"
        );
        assert_eq!(
            ssot_offset_max(et),
            ssot_pow3(et) - 1,
            "offset_max = 3^Et-1"
        );
    }
    assert_eq!(
        ssot_mant_one(25) * 2,
        ssot_mant_one(26),
        "mant_one is 2^mant_bits"
    );
}
