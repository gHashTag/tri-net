`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot2_64 -- 2-term GF-T64 dot product: y = a1*b1 + a2*b2. Lifts GF-T64 from
// multiply-only (gft_mul64) to multiply-accumulate, the way gft_dot2/_32/_8 did for
// the lower rungs -- so the whole ladder now has a MAC. Composition of two wide
// gft_mul64 (256-bit significand product) with the wide gft_add64 (128-bit sum).
//
// GF-T64: bias 9841, offset_max 19682, mant_one 2^64. Operands/result are (offset,
// mant) pairs: offset up to 19682 (15 bits), mantissa 64 bits. Combinational.
// ============================================================================
module gft_dot2_64 (
    input  wire [31:0] a1_off,
    input  wire [63:0] a1_mant,
    input  wire [31:0] b1_off,
    input  wire [63:0] b1_mant,
    input  wire [31:0] a2_off,
    input  wire [63:0] a2_mant,
    input  wire [31:0] b2_off,
    input  wire [63:0] b2_mant,
    output wire [31:0] out_off,
    output wire [63:0] out_mant
);
    wire [31:0] p1_off, p2_off;
    wire [63:0] p1_mant, p2_mant;
    gft_mul64 #(.BIAS(32'd9841), .OFFSET_MAX(32'd19682), .MANT_ONE(128'h1_0000_0000_0000_0000)) u_m1 (
        .a_off(a1_off), .a_mant(a1_mant), .b_off(b1_off), .b_mant(b1_mant),
        .out_off(p1_off), .out_mant(p1_mant));
    gft_mul64 #(.BIAS(32'd9841), .OFFSET_MAX(32'd19682), .MANT_ONE(128'h1_0000_0000_0000_0000)) u_m2 (
        .a_off(a2_off), .a_mant(a2_mant), .b_off(b2_off), .b_mant(b2_mant),
        .out_off(p2_off), .out_mant(p2_mant));

    gft_add64 #(.OFFSET_MAX(32'd19682), .MANT_ONE(128'h1_0000_0000_0000_0000), .SIG_BITS(32'd65)) u_acc (
        .a_off(p1_off), .a_mant(p1_mant),
        .b_off(p2_off), .b_mant(p2_mant),
        .out_off(out_off), .out_mant(out_mant));
endmodule
`default_nettype wire
