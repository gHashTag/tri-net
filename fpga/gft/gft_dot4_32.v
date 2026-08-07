`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot4_32 -- 4-lane GF-T32 multiply-accumulate (dot product): the top-rung
// scaling primitive, mirroring gft_dot4.v (GF-T16) at the wide rung. Deepens the
// GF-T32 line from dot2 (gft_dot2_32) to a full 4-lane reduction tree.
//
// Like gft_dot2_32 it must use the WIDE gft_mul32 (64-bit significand product,
// ~2^52 at mant_one=2^25) -- the base gft_mul would silently overflow. The
// reduction tree is three gft_add stages; the GF-T32 significand SUM stays within
// 32 bits (<2^27), so the standard gft_add covers it. Combinational.
//
// GF-T32: bias 364, offset_max 728, mant_one 2^25. value = (1 + M/2^25) *
// 2^(offset-364). Operands packed as 4x u32 lanes: lane i is bits [32*i +: 32].
// ============================================================================
module gft_dot4_32 #(
    parameter [31:0] BIAS       = 364,
    parameter [31:0] OFFSET_MAX = 728,
    parameter [63:0] MANT_ONE   = 64'd33554432,  // 2^25
    parameter [31:0] SIG_BITS   = 26             // mant_bits(25) + 1
) (
    input  wire [127:0] a_off,   // 4 lanes x 32b
    input  wire [127:0] a_mant,
    input  wire [127:0] b_off,
    input  wire [127:0] b_mant,
    output wire [31:0]  out_off,
    output wire [31:0]  out_mant
);
    wire [31:0] mo [0:3];
    wire [31:0] mm [0:3];
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : lane
            gft_mul32 #(.BIAS(BIAS), .OFFSET_MAX(OFFSET_MAX), .MANT_ONE(MANT_ONE)) u_mul (
                a_off[32*i +: 32], a_mant[32*i +: 32], b_off[32*i +: 32], b_mant[32*i +: 32],
                mo[i], mm[i]);
        end
    endgenerate

    // Reduction tree: (m0+m1) + (m2+m3). GF-T32 sum fits 32 bits, standard gft_add.
    wire [31:0] s01o, s01m, s23o, s23m;
    gft_add #(.OFFSET_MAX(OFFSET_MAX), .MANT_ONE(MANT_ONE[31:0]), .SIG_BITS(SIG_BITS)) a01 (mo[0], mm[0], mo[1], mm[1], s01o, s01m);
    gft_add #(.OFFSET_MAX(OFFSET_MAX), .MANT_ONE(MANT_ONE[31:0]), .SIG_BITS(SIG_BITS)) a23 (mo[2], mm[2], mo[3], mm[3], s23o, s23m);
    gft_add #(.OFFSET_MAX(OFFSET_MAX), .MANT_ONE(MANT_ONE[31:0]), .SIG_BITS(SIG_BITS)) atop (s01o, s01m, s23o, s23m, out_off, out_mant);
endmodule
`default_nettype wire
