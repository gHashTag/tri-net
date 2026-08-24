`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul4 -- GF-T4 multiplier, the BOTTOM rung of the ladder (Et2, 1-bit mantissa).
// Completes the silicon ladder: gft_mul4 / gft_mul8_seq / gft_mul (GF-T16) /
// gft_mul32 / gft_mul64 now cover GF-T4..GF-T64. GF-T4 is the ternary-native rung --
// its 1-bit mantissa means only two significands {1.0, 1.5}, so a product rounds
// toward zero to the nearest representable value (the 4-bit tapered-float analogue of
// BitNet-1.58 / ternary weights, but WITH a 2-trit exponent for dynamic range).
//
// GF-T4: bias 4, offset_max 8, mant_one 2. value = (1 + M/2) * 2^(offset - 4), M in
// {0,1}. Significand product is tiny, so the base gft_mul 32-bit datapath is exact.
// ============================================================================
module gft_mul4 #(
    parameter [31:0] BIAS       = 32'd4,
    parameter [31:0] OFFSET_MAX = 32'd8,
    parameter [31:0] MANT_ONE   = 32'd2
) (
    input  wire [31:0] a_off,
    input  wire [31:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [31:0] b_mant,
    output wire [31:0] out_off,
    output wire [31:0] out_mant
);
    gft_mul #(.BIAS(BIAS), .OFFSET_MAX(OFFSET_MAX), .MANT_ONE(MANT_ONE)) u_mul (
        .a_off(a_off), .a_mant(a_mant), .b_off(b_off), .b_mant(b_mant),
        .out_off(out_off), .out_mant(out_mant));
endmodule
`default_nettype wire
