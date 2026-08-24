`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft16_mul -- GF-T16 multiplier, field-width-narrowed for area.
//
// A thin wrapper over the parametric gft_mul (specs/tri_gft_arith.t27), with
// ports sized to the actual GF-T16 field widths: exponent offset 0..80 fits 7
// bits, mantissa field 0..511 fits 9 bits. Zero-extending into gft_mul lets
// synthesis constant-propagate the upper bits away, so the significand product
// collapses from a 32x32 multiply (3 DSP48E1) to a 10x10 one (1 DSP48E1). No
// logic is duplicated -- the arithmetic stays in the spec-faithful gft_mul.
// ============================================================================
module gft16_mul (
    input  wire [6:0] a_off,
    input  wire [8:0] a_mant,
    input  wire [6:0] b_off,
    input  wire [8:0] b_mant,
    output wire [6:0] out_off,
    output wire [8:0] out_mant
);
    wire [31:0] o, m;
    gft_mul #(.BIAS(40), .OFFSET_MAX(80), .MANT_ONE(512)) u_core (
        .a_off ({25'd0, a_off}),  .a_mant({23'd0, a_mant}),
        .b_off ({25'd0, b_off}),  .b_mant({23'd0, b_mant}),
        .out_off(o), .out_mant(m)
    );
    assign out_off  = o[6:0];
    assign out_mant = m[8:0];
endmodule
`default_nettype wire
