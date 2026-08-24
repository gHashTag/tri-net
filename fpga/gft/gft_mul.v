`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul -- GF-T ladder multiplier (balanced-ternary exponent).
//
// Verified realization of specs/tri_gft_arith.t27's gft_mul_offset_full_p +
// gft_mul_mant_p + gft_mul_mant_carry_p -- the SAME spec the over-wire verifier
// runs (trinet_compute_over_mesh / trinet_rung_verify). SSOT is the .t27; this
// .v is the synthesizable realization (as fpga/gf16/gf16_mul.v is for GF16).
//
// t27c gen-verilog cannot emit this directly yet: it interleaves `reg`
// declarations with statements inside begin/end blocks (illegal Verilog; iverilog
// rejects it). Tracked upstream; this hand-transcription keeps the exact logic
// with legal declaration ordering, gated by an iverilog KAT sweep below.
//
// Combinational. Parametric per rung; GF-T16 defaults (bias 40, offset_max 80,
// mant_one 512). GF-T8 = (13, 26, 16); GF-T4 = (4, 8, 2); GF-T32 uses wider mant.
// ============================================================================
module gft_mul #(
    parameter [31:0] BIAS       = 40,
    parameter [31:0] OFFSET_MAX = 80,
    parameter [31:0] MANT_ONE   = 512
) (
    input  wire [31:0] a_off,
    input  wire [31:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [31:0] b_mant,
    output wire [31:0] out_off,
    output wire [31:0] out_mant
);
    // Full-precision significand product (1+M/mant_one) scaled by mant_one^2.
    wire [31:0] prod   = (MANT_ONE + a_mant) * (MANT_ONE + b_mant);
    wire [31:0] thresh = (2 * MANT_ONE) * MANT_ONE;      // one-bit renorm boundary
    wire        carry  = (prod >= thresh);               // mantissa overflow -> exp += 1

    // Exponent offset: add offsets, apply the carry, de-bias, saturate at the rung's max.
    wire [31:0] sum    = a_off + b_off + {31'd0, carry};
    wire [31:0] result = sum - BIAS;
    assign out_off = (sum < BIAS)          ? 32'd0 :
                     (result >= OFFSET_MAX) ? OFFSET_MAX : result;

    // Mantissa: renormalize by the carry (divisors are constant powers of two -> shifts).
    assign out_mant = carry ? ((prod / (2 * MANT_ONE)) - MANT_ONE)
                            : ((prod /      MANT_ONE ) - MANT_ONE);
endmodule
`default_nettype wire
