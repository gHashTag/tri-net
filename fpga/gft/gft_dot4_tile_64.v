`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot4_tile_64 -- tileable GF-T64 4-lane MAC, the wide-rung matmul primitive
// (cf. gft_dot4_tile.v GF-T16, gft_dot4_tile_32.v GF-T32). Narrow PACKED ports so
// many tiles array into a systolic matmul without 96-bit-per-lane fan-out: each
// GF-T64 element is 79 bits (15-bit offset + 64-bit mantissa), so an operand vector
// is 4x79 = 316 bits (offset 4x16 packed + mantissa 4x64).
//
// Four gft_mul64 (256-bit significand product, ~2^130) reduced by a 3-adder gft_add64
// (128-bit sum) tree. Same golden results as gft_dot4_64 -- a pure composition of the
// over-wire-verified gft_mul64 + gft_add64 stages. Combinational.
//
// GF-T64: bias 9841, offset_max 19682, mant_one 2^64. value = (1 + M/2^64)*2^(off-9841).
// ============================================================================
module gft_dot4_tile_64 (
    input  wire [63:0]  a_off,   // 4 lanes x 16b (offset <= 19682 fits 15b)
    input  wire [255:0] a_mant,  // 4 lanes x 64b
    input  wire [63:0]  b_off,
    input  wire [255:0] b_mant,
    output wire [15:0]  out_off,
    output wire [63:0]  out_mant
);
    wire [31:0] mo [0:3];
    wire [63:0] mm [0:3];
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : lane
            gft_mul64 #(.BIAS(32'd9841), .OFFSET_MAX(32'd19682), .MANT_ONE(128'h1_0000_0000_0000_0000)) u_mul (
                {16'd0, a_off[16*i +: 16]}, a_mant[64*i +: 64],
                {16'd0, b_off[16*i +: 16]}, b_mant[64*i +: 64],
                mo[i], mm[i]);
        end
    endgenerate

    // Reduction tree: (m0+m1) + (m2+m3), wide gft_add64.
    wire [31:0] s01o, s23o, too;
    wire [63:0] s01m, s23m, tom;
    gft_add64 a01 (mo[0], mm[0], mo[1], mm[1], s01o, s01m);
    gft_add64 a23 (mo[2], mm[2], mo[3], mm[3], s23o, s23m);
    gft_add64 atop (s01o, s01m, s23o, s23m, too, tom);
    assign out_off  = too[15:0];
    assign out_mant = tom;
endmodule
`default_nettype wire
