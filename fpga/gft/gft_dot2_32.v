`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot2_32 -- 2-term GF-T32 dot product (the top-rung MAC): y = a1*b1 + a2*b2.
// Deepens the GF-T32 rung from multiply-only to multiply-accumulate. Composition of
// the wide gft_mul32 (64-bit significand product) with gft_add at GF-T32 params.
//
// Note the asymmetry: the GF-T32 significand PRODUCT reaches ~2^52 (needs gft_mul32's
// 64-bit datapath), but the significand SUM in gft_add is only (2^25+hi)+sb < 2^27,
// so the 32-bit gft_add already covers GF-T32 -- no wide adder needed. Combinational.
//
// GF-T32: bias 364, offset_max 728, mant_one 2^25. Operands/result are (offset, mant)
// pairs (offset up to 728 in 10 bits, mantissa up to 2^25-1 in 25 bits).
// ============================================================================
module gft_dot2_32 (
    input  wire [31:0] a1_off,
    input  wire [31:0] a1_mant,
    input  wire [31:0] b1_off,
    input  wire [31:0] b1_mant,
    input  wire [31:0] a2_off,
    input  wire [31:0] a2_mant,
    input  wire [31:0] b2_off,
    input  wire [31:0] b2_mant,
    output wire [31:0] out_off,
    output wire [31:0] out_mant
);
    wire [31:0] p1_off, p1_mant, p2_off, p2_mant;
    gft_mul32 #(.BIAS(364), .OFFSET_MAX(728), .MANT_ONE(64'd33554432)) u_m1 (
        .a_off(a1_off), .a_mant(a1_mant), .b_off(b1_off), .b_mant(b1_mant),
        .out_off(p1_off), .out_mant(p1_mant));
    gft_mul32 #(.BIAS(364), .OFFSET_MAX(728), .MANT_ONE(64'd33554432)) u_m2 (
        .a_off(a2_off), .a_mant(a2_mant), .b_off(b2_off), .b_mant(b2_mant),
        .out_off(p2_off), .out_mant(p2_mant));

    // GF-T32 significand sum stays within 32 bits, so the standard gft_add covers it.
    gft_add #(.OFFSET_MAX(728), .MANT_ONE(33554432), .SIG_BITS(26)) u_acc (
        .a_off(p1_off), .a_mant(p1_mant),
        .b_off(p2_off), .b_mant(p2_mant),
        .out_off(out_off), .out_mant(out_mant));
endmodule
`default_nettype wire
