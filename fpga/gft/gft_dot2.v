`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot2 -- 2-term GF-T16 dot product: y = a1*b1 + a2*b2, the multiply-accumulate
// kernel at the heart of every matmul / attention / inference layer. Pure composition
// of the silicon-proven gft_mul with gft_add (both realizations of tri_gft_arith /
// tri_gft_add) -- no new arithmetic, just the MAC wiring. Combinational.
//
// This is the hardware twin of the NUMERICAL dot-product advantage measured in
// tests/gft_task_accuracy.rs: there GF-T16 owns the wide-dynamic-range dot product on
// paper; here the same dot product is computed in GF-T16 hardware, bit-exact to spec.
//
// Operands/result are packed GF-T16 magnitudes: [ offset:15..9 (7b) | mant:8..0 (9b) ],
// value = (1 + mant/512) * 2^(offset-40).
// ============================================================================
module gft_dot2 (
    input  wire [15:0] a1,
    input  wire [15:0] b1,
    input  wire [15:0] a2,
    input  wire [15:0] b2,
    output wire [15:0] y
);
    // term 1 = a1 * b1
    wire [31:0] p1_off, p1_mant;
    gft_mul #(.BIAS(40), .OFFSET_MAX(80), .MANT_ONE(512)) u_m1 (
        .a_off({25'd0, a1[15:9]}), .a_mant({23'd0, a1[8:0]}),
        .b_off({25'd0, b1[15:9]}), .b_mant({23'd0, b1[8:0]}),
        .out_off(p1_off), .out_mant(p1_mant));

    // term 2 = a2 * b2
    wire [31:0] p2_off, p2_mant;
    gft_mul #(.BIAS(40), .OFFSET_MAX(80), .MANT_ONE(512)) u_m2 (
        .a_off({25'd0, a2[15:9]}), .a_mant({23'd0, a2[8:0]}),
        .b_off({25'd0, b2[15:9]}), .b_mant({23'd0, b2[8:0]}),
        .out_off(p2_off), .out_mant(p2_mant));

    // accumulate: term1 + term2 (same-sign GF-T add)
    wire [31:0] y_off, y_mant;
    gft_add #(.OFFSET_MAX(80), .MANT_ONE(512), .SIG_BITS(10)) u_acc (
        .a_off(p1_off), .a_mant(p1_mant),
        .b_off(p2_off), .b_mant(p2_mant),
        .out_off(y_off), .out_mant(y_mant));

    assign y = {y_off[6:0], y_mant[8:0]};
endmodule
`default_nettype wire
