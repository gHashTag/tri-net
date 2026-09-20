//! ladder_bias_vs_silicon -- close the SSOT-onto-silicon loop: the GF-T ladder's bias (from the
//! golden rule, ladder_canon_ssot) must equal the bias hardcoded in the synthesizable multipliers.
//! tri_gft_ladder computes bias(Et) = (3^Et - 1)/2; the silicon gft_mul32.v / gft_mul64.v carry a
//! `parameter BIAS = ...`. If the SSOT and the hardware ever disagree (as they did when Et was once
//! log2 instead of the golden fib rule -- GF-T32 log2 bias 121 vs silicon 364), a result offset would
//! be biased differently in Rust than on chip. This reads the ACTUAL Verilog with include_str! and
//! asserts each BIAS matches the SSOT formula -- a real spec<->silicon cross-check, not a re-assertion.

const MUL32_V: &str = include_str!("../fpga/gft/gft_mul32.v");
const MUL64_V: &str = include_str!("../fpga/gft/gft_mul64.v");

/// bias(Et) = (3^Et - 1)/2 from the ladder SSOT (u64 for the upper rungs).
fn ssot_bias(et: u32) -> u64 {
    let pow3: u64 = (0..et).fold(1u64, |acc, _| acc * 3);
    (pow3 - 1) / 2
}

/// Extract the `parameter [..] BIAS = <number>` value from a Verilog module source.
fn verilog_bias_param(src: &str) -> u64 {
    for line in src.lines() {
        let t = line.trim();
        // match a line declaring the BIAS parameter, e.g. "parameter [31:0] BIAS = 364,"
        if t.starts_with("parameter") && t.contains("BIAS") && t.contains('=') {
            let after_eq = t.split('=').nth(1).expect("BIAS line has '='");
            // take the numeric token; strip a Verilog sized literal prefix like "32'd9841".
            let tok: String = after_eq
                .trim()
                .trim_start_matches(|c: char| {
                    c.is_ascii_digit() || c == '\'' || c == 'd' || c == 'h' || c == 'b'
                })
                .to_string();
            let _ = tok; // (unused; we parse digits directly below)
            let digits: String = after_eq
                .chars()
                .skip_while(|c| !c.is_ascii_digit())
                .take_while(|c| c.is_ascii_digit())
                .collect();
            // For "32'd9841" the first digit run is "32" (the width). Prefer the run AFTER a "'d".
            if let Some(idx) = after_eq.find("'d") {
                let d: String = after_eq[idx + 2..]
                    .chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                return d.parse().expect("BIAS numeric");
            }
            if let Some(idx) = after_eq.find("'h") {
                let h: String = after_eq[idx + 2..]
                    .chars()
                    .take_while(|c| c.is_ascii_hexdigit())
                    .collect();
                return u64::from_str_radix(&h, 16).expect("BIAS hex");
            }
            return digits.parse().expect("BIAS numeric");
        }
    }
    panic!("no BIAS parameter found in the Verilog source");
}

#[test]
fn the_ssot_bias_formula_gives_the_known_rung_biases() {
    assert_eq!(ssot_bias(6), 364, "GF-T32: (3^6-1)/2");
    assert_eq!(ssot_bias(9), 9841, "GF-T64: (3^9-1)/2");
    assert_eq!(ssot_bias(4), 40, "GF-T16: (3^4-1)/2");
    // the log2 regression value, for contrast: (3^5-1)/2 = 121 -- NOT what silicon uses.
    assert_eq!(ssot_bias(5), 121, "Et5 (the old log2 GF-T32) would be 121");
}

#[test]
fn the_gft_mul32_silicon_bias_matches_the_ssot_gf_t32_rung() {
    let silicon = verilog_bias_param(MUL32_V);
    assert_eq!(silicon, 364, "gft_mul32.v BIAS parameter reads 364");
    assert_eq!(
        silicon,
        ssot_bias(6),
        "silicon GF-T32 bias == SSOT (3^6-1)/2 (Et6, golden rule)"
    );
    assert_ne!(silicon, ssot_bias(5), "and NOT the log2-Et5 bias 121");
}

#[test]
fn the_gft_mul64_silicon_bias_matches_the_ssot_gf_t64_rung() {
    let silicon = verilog_bias_param(MUL64_V);
    assert_eq!(silicon, 9841, "gft_mul64.v BIAS parameter reads 9841");
    assert_eq!(
        silicon,
        ssot_bias(9),
        "silicon GF-T64 bias == SSOT (3^9-1)/2"
    );
}
