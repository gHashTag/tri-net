`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot2_4 -- 2-term GF-T4 dot product: y = a1*b1 + a2*b2, the MAC kernel at the
// BOTTOM rung. Completes GF-T4 symmetrically with the other rungs (mul4 -> dot2_4),
// mirroring gft_dot2_8 (GF-T8). GF-T4 significands are tiny (mant_one = 2), so the
// base gft_mul (via gft_mul4) and the standard gft_add both cover it trivially --
// no wide datapath. Products round toward zero on the 1-bit-mantissa grid, then the
// accumulate renormalizes. Combinational.
//
// GF-T4: bias 4, offset_max 8, mant_one 2, sig_bits 2 (mant_bits 1 + 1). value =
// (1 + M/2) * 2^(offset - 4), M in {0,1}. Operands/result are (offset, mant) pairs.
// ============================================================================
module gft_dot2_4 (
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
    gft_mul4 #(.BIAS(32'd4), .OFFSET_MAX(32'd8), .MANT_ONE(32'd2)) u_m1 (
        .a_off(a1_off), .a_mant(a1_mant), .b_off(b1_off), .b_mant(b1_mant),
        .out_off(p1_off), .out_mant(p1_mant));
    gft_mul4 #(.BIAS(32'd4), .OFFSET_MAX(32'd8), .MANT_ONE(32'd2)) u_m2 (
        .a_off(a2_off), .a_mant(a2_mant), .b_off(b2_off), .b_mant(b2_mant),
        .out_off(p2_off), .out_mant(p2_mant));

    gft_add #(.OFFSET_MAX(32'd8), .MANT_ONE(32'd2), .SIG_BITS(32'd2)) u_acc (
        .a_off(p1_off), .a_mant(p1_mant),
        .b_off(p2_off), .b_mant(p2_mant),
        .out_off(out_off), .out_mant(out_mant));
endmodule
`default_nettype wire
