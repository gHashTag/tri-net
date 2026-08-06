`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot4_tile -- area-narrowed GF-T16 4-lane MAC, the tileable ternary-compute
// unit. Built from four proven single-DSP gft16_mul multipliers (offset 7b,
// mantissa 9b) reduced by a 3-adder gft_add tree -> ~4 DSP48E1 total, vs 12 for the
// u32 gft_dot4. Same golden results (composition of over-wire-verified mul+add).
// ============================================================================
module gft_dot4_tile (
    input  wire [27:0] a_off,   // 4 lanes x 7b
    input  wire [35:0] a_mant,  // 4 lanes x 9b
    input  wire [27:0] b_off,
    input  wire [35:0] b_mant,
    output wire [6:0]  out_off,
    output wire [8:0]  out_mant
);
    wire [6:0] mo [0:3];
    wire [8:0] mm [0:3];
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : lane
            gft16_mul u_mul (a_off[7*i +: 7], a_mant[9*i +: 9], b_off[7*i +: 7], b_mant[9*i +: 9], mo[i], mm[i]);
        end
    endgenerate
    // Reduction tree in gft_add (32b ports, LUT-only): (m0+m1) + (m2+m3).
    wire [31:0] s01o, s01m, s23o, s23m, too, tom;
    gft_add a01 ({25'd0,mo[0]}, {23'd0,mm[0]}, {25'd0,mo[1]}, {23'd0,mm[1]}, s01o, s01m);
    gft_add a23 ({25'd0,mo[2]}, {23'd0,mm[2]}, {25'd0,mo[3]}, {23'd0,mm[3]}, s23o, s23m);
    gft_add atop (s01o, s01m, s23o, s23m, too, tom);
    assign out_off  = too[6:0];
    assign out_mant = tom[8:0];
endmodule
`default_nettype wire
