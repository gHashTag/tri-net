`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot4_tile_32 -- tileable GF-T32 4-lane MAC, the top-rung matmul primitive
// (cf. gft_dot4_tile.v for GF-T16). Narrow PACKED ports so many tiles array into a
// systolic matmul without 32-bit-per-lane fan-out: each GF-T32 element is 35 bits
// (10-bit offset + 25-bit mantissa), so an operand vector is 4x35 = 140 bits.
//
// Four wide gft_mul32 (64-bit significand product, ~2^52 -- the base gft_mul would
// overflow at mant_one=2^25) reduced by a 3-adder gft_add tree. yosys maps each
// gft_mul32 onto DSP48E1 tiles, so a tile is DSP-bounded and area-characterizable
// (see synth_gft_dot4_tile_32.ys). Same golden results as gft_dot4_32 -- a pure
// composition of the over-wire-verified gft_mul32 + gft_add stages. Combinational.
//
// GF-T32: bias 364, offset_max 728, mant_one 2^25. value = (1 + M/2^25)*2^(off-364).
// ============================================================================
module gft_dot4_tile_32 (
    input  wire [39:0] a_off,   // 4 lanes x 10b
    input  wire [99:0] a_mant,  // 4 lanes x 25b
    input  wire [39:0] b_off,
    input  wire [99:0] b_mant,
    output wire [9:0]  out_off,
    output wire [24:0] out_mant
);
    wire [31:0] mo [0:3];
    wire [31:0] mm [0:3];
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : lane
            gft_mul32 #(.BIAS(364), .OFFSET_MAX(728), .MANT_ONE(64'd33554432)) u_mul (
                .a_off({22'd0, a_off[10*i +: 10]}), .a_mant({7'd0, a_mant[25*i +: 25]}),
                .b_off({22'd0, b_off[10*i +: 10]}), .b_mant({7'd0, b_mant[25*i +: 25]}),
                .out_off(mo[i]), .out_mant(mm[i]));
        end
    endgenerate

    // Reduction tree: (m0+m1) + (m2+m3). GF-T32 sum stays < 2^27, 32-bit gft_add covers it.
    wire [31:0] s01o, s01m, s23o, s23m, too, tom;
    gft_add #(.OFFSET_MAX(728), .MANT_ONE(33554432), .SIG_BITS(26)) a01 (mo[0], mm[0], mo[1], mm[1], s01o, s01m);
    gft_add #(.OFFSET_MAX(728), .MANT_ONE(33554432), .SIG_BITS(26)) a23 (mo[2], mm[2], mo[3], mm[3], s23o, s23m);
    gft_add #(.OFFSET_MAX(728), .MANT_ONE(33554432), .SIG_BITS(26)) atop (s01o, s01m, s23o, s23m, too, tom);
    assign out_off  = too[9:0];
    assign out_mant = tom[24:0];
endmodule
`default_nettype wire
