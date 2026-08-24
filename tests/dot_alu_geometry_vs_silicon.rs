//! dot_alu_geometry_vs_silicon -- finish the SSOT<->silicon geometry sweep: the DOT/ALU/SUB cores.
//! After the multiplier (ladder_geometry_vs_silicon, low_rung_geometry_vs_silicon) and adder
//! (adder_geometry_vs_silicon) checks, the remaining parameterized synthesizable .v files were the
//! 4-lane dot units (gft_dot4.v GF-T16, gft_dot4_32.v GF-T32), the combined ALU (gft_alu.v), and
//! the subtractor (gft_sub.v). All carry the same rung geometry -- BIAS = (3^Et-1)/2, OFFSET_MAX =
//! 3^Et-1, MANT_ONE = 2^mant_bits, MANT_BITS / SIG_BITS -- plus the subtract-path ALIGN_CAP, whose
//! SSOT is the spec constant in specs/tri_gft_sub.t27 and whose shape is 32 - (mant_bits + 1) (the
//! largest exact left-shift that cannot overflow u32). Reads the ACTUAL Verilog AND the actual spec
//! with include_str!, so no parameterized GF-T datapath core is outside the one-geometry table.

const DOT4_16_V: &str = include_str!("../fpga/gft/gft_dot4.v");
const DOT4_32_V: &str = include_str!("../fpga/gft/gft_dot4_32.v");
const ALU_V: &str = include_str!("../fpga/gft/gft_alu.v");
const SUB_V: &str = include_str!("../fpga/gft/gft_sub.v");
const SUB_SPEC: &str = include_str!("../specs/tri_gft_sub.t27");

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
/// The largest alignment shift whose exact `(MANT_ONE + m) << d` still fits u32: the significand
/// occupies mant_bits + 1 bits, so d caps at 32 - (mant_bits + 1).
fn ssot_align_cap(mant_bits: u32) -> u128 {
    (32 - (mant_bits + 1)) as u128
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

#[test]
fn the_gf_t16_dot4_geometry_matches_the_ssot_rung() {
    // GF-T16 is Et4, mant_bits 9.
    assert_eq!(
        verilog_param(DOT4_16_V, "BIAS"),
        ssot_bias(4),
        "dot4 bias == 40"
    );
    assert_eq!(
        verilog_param(DOT4_16_V, "OFFSET_MAX"),
        ssot_offset_max(4),
        "dot4 offset_max == 80"
    );
    assert_eq!(
        verilog_param(DOT4_16_V, "MANT_ONE"),
        ssot_mant_one(9),
        "dot4 mant_one == 512"
    );
    assert_eq!(
        verilog_param(DOT4_16_V, "MANT_BITS"),
        9,
        "dot4 mant_bits == 9"
    );
}

#[test]
fn the_gf_t32_dot4_geometry_matches_the_ssot_rung() {
    // GF-T32 is Et6, mant_bits 25; sig_bits = 26.
    assert_eq!(
        verilog_param(DOT4_32_V, "BIAS"),
        ssot_bias(6),
        "dot4_32 bias == 364"
    );
    assert_eq!(
        verilog_param(DOT4_32_V, "OFFSET_MAX"),
        ssot_offset_max(6),
        "dot4_32 offset_max == 728"
    );
    assert_eq!(
        verilog_param(DOT4_32_V, "MANT_ONE"),
        ssot_mant_one(25),
        "dot4_32 mant_one == 2^25"
    );
    assert_eq!(
        verilog_param(DOT4_32_V, "SIG_BITS"),
        26,
        "dot4_32 sig_bits == mant_bits + 1"
    );
}

#[test]
fn the_alu_geometry_matches_the_ssot_rung_and_the_sub_align_cap() {
    // The combined ALU is the GF-T16 rung with the subtract path folded in.
    assert_eq!(verilog_param(ALU_V, "BIAS"), ssot_bias(4), "alu bias == 40");
    assert_eq!(
        verilog_param(ALU_V, "OFFSET_MAX"),
        ssot_offset_max(4),
        "alu offset_max == 80"
    );
    assert_eq!(
        verilog_param(ALU_V, "MANT_ONE"),
        ssot_mant_one(9),
        "alu mant_one == 512"
    );
    assert_eq!(verilog_param(ALU_V, "MANT_BITS"), 9, "alu mant_bits == 9");
    assert_eq!(
        verilog_param(ALU_V, "ALIGN_CAP"),
        ssot_align_cap(9),
        "alu align_cap == 22"
    );
}

#[test]
fn the_subtractor_align_cap_matches_the_spec_constant_and_its_derivation() {
    // Three-way lock: silicon parameter == spec const (tri_gft_sub.t27) == the u32-overflow
    // derivation 32 - (mant_bits + 1). If any leg drifts, the far/near subtract split moves.
    let silicon = verilog_param(SUB_V, "ALIGN_CAP");
    let spec = spec_const(SUB_SPEC, "ALIGN_CAP");
    let mant_bits = verilog_param(SUB_V, "MANT_BITS") as u32;
    assert_eq!(silicon, spec, "silicon ALIGN_CAP == spec const");
    assert_eq!(
        silicon,
        ssot_align_cap(mant_bits),
        "ALIGN_CAP == 32 - (mant_bits + 1)"
    );
    assert_eq!(
        verilog_param(SUB_V, "MANT_ONE"),
        ssot_mant_one(mant_bits),
        "sub mant_one"
    );
}

#[test]
fn the_alu_and_sub_share_one_gf_t16_geometry() {
    // The standalone subtractor and the ALU's subtract path must be the same core.
    for name in ["MANT_ONE", "MANT_BITS", "ALIGN_CAP"] {
        assert_eq!(
            verilog_param(ALU_V, name),
            verilog_param(SUB_V, name),
            "alu and sub agree on {name}"
        );
    }
}
