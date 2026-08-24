//! low_rung_geometry_vs_silicon -- complete the SSOT<->silicon geometry sweep DOWN the ladder.
//! ladder_bias_vs_silicon + ladder_geometry_vs_silicon pinned the GF-T32/64 multipliers and
//! adder_geometry_vs_silicon the GF-T16/64 adders; the LOW rungs' multipliers -- gft_mul.v (GF-T16)
//! and gft_mul4.v (GF-T4) -- carry the same `parameter BIAS / OFFSET_MAX / MANT_ONE` and were still
//! unchecked. Reads the ACTUAL Verilog with include_str! and asserts every parameter equals the
//! tri_gft_ladder SSOT formulas: bias = (3^Et-1)/2, offset_max = 3^Et-1, mant_one = 2^mant_bits.
//! With this, every parameterized GF-T mul/add .v on every rung is pinned to one ladder geometry.

const MUL16_V: &str = include_str!("../fpga/gft/gft_mul.v");
const MUL4_V: &str = include_str!("../fpga/gft/gft_mul4.v");

fn ssot_pow3(et: u32) -> u128 {
    (0..et).fold(1u128, |acc, _| acc * 3)
}
fn ssot_offset_max(et: u32) -> u128 {
    ssot_pow3(et) - 1
}
fn ssot_bias(et: u32) -> u128 {
    ssot_offset_max(et) / 2
}
fn ssot_mant_one(mant_bits: u32) -> u128 {
    1u128 << mant_bits
}

/// Extract `parameter [..] NAME = <literal>` as a u128. Handles a bare decimal and a Verilog sized
/// literal `<w>'d<dec>` / `<w>'h<hex>`; stops at the first non-digit so a comment cannot leak in.
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
fn the_gf_t16_multiplier_geometry_matches_the_ssot_rung() {
    // GF-T16 is Et4, mant_bits 9 (the ratified ladder): bias 40, offset_max 80, mant_one 512.
    assert_eq!(
        verilog_param(MUL16_V, "BIAS"),
        ssot_bias(4),
        "GF-T16 bias == (3^4-1)/2 = 40"
    );
    assert_eq!(
        verilog_param(MUL16_V, "OFFSET_MAX"),
        ssot_offset_max(4),
        "GF-T16 offset_max == 80"
    );
    assert_eq!(
        verilog_param(MUL16_V, "MANT_ONE"),
        ssot_mant_one(9),
        "GF-T16 mant_one == 2^9 = 512"
    );
}

#[test]
fn the_gf_t4_multiplier_geometry_matches_the_ssot_rung() {
    // GF-T4 is Et2, mant_bits 1 (the lowest rung): bias 4, offset_max 8, mant_one 2.
    assert_eq!(
        verilog_param(MUL4_V, "BIAS"),
        ssot_bias(2),
        "GF-T4 bias == (3^2-1)/2 = 4"
    );
    assert_eq!(
        verilog_param(MUL4_V, "OFFSET_MAX"),
        ssot_offset_max(2),
        "GF-T4 offset_max == 8"
    );
    assert_eq!(
        verilog_param(MUL4_V, "MANT_ONE"),
        ssot_mant_one(1),
        "GF-T4 mant_one == 2^1 = 2"
    );
}

#[test]
fn the_multiplier_and_adder_agree_on_the_gf_t16_rung() {
    // gft_mul.v and gft_add.v implement the SAME GF-T16 rung: their shared parameters must agree,
    // so the ALU cannot mix two geometries on one width.
    let add16 = include_str!("../fpga/gft/gft_add.v");
    assert_eq!(
        verilog_param(MUL16_V, "OFFSET_MAX"),
        verilog_param(add16, "OFFSET_MAX"),
        "mul and add share one GF-T16 offset ceiling"
    );
    assert_eq!(
        verilog_param(MUL16_V, "MANT_ONE"),
        verilog_param(add16, "MANT_ONE"),
        "mul and add share one GF-T16 mantissa scale"
    );
}
