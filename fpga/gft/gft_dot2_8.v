`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot2_8 -- 2-term GF-T8 dot product: y = a1*b1 + a2*b2, the MAC kernel at the
// SMALL rung. Fills the GF-T8 gap: the rung had only gft_mul8_seq (multiply); this
// deepens it to multiply-accumulate, mirroring gft_dot2 (GF-T16) / gft_dot2_32.
//
// GF-T8 significands are tiny (mant_one = 2^4), so the base gft_mul (32-bit) and the
// standard gft_add both cover it with room to spare -- no wide datapath needed.
// Combinational.
//
// GF-T8: bias 13, offset_max 26, mant_one 2^4=16, sig_bits 5 (mant_bits 4 + 1).
// value = (1 + M/16) * 2^(offset-13). Operands/result are (offset, mant) pairs
// (offset up to 26 in 5 bits, mantissa up to 15 in 4 bits).
// ============================================================================
module gft_dot2_8 (
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
    gft_mul #(.BIAS(13), .OFFSET_MAX(26), .MANT_ONE(16)) u_m1 (
        .a_off(a1_off), .a_mant(a1_mant), .b_off(b1_off), .b_mant(b1_mant),
        .out_off(p1_off), .out_mant(p1_mant));
    gft_mul #(.BIAS(13), .OFFSET_MAX(26), .MANT_ONE(16)) u_m2 (
        .a_off(a2_off), .a_mant(a2_mant), .b_off(b2_off), .b_mant(b2_mant),
        .out_off(p2_off), .out_mant(p2_mant));

    gft_add #(.OFFSET_MAX(26), .MANT_ONE(16), .SIG_BITS(5)) u_acc (
        .a_off(p1_off), .a_mant(p1_mant),
        .b_off(p2_off), .b_mant(p2_mant),
        .out_off(out_off), .out_mant(out_mant));
endmodule
`default_nettype wire
