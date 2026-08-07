`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot4_64 -- 4-lane GF-T64 multiply-accumulate (dot product), the wide-rung
// scaling primitive (cf. gft_dot4 for GF-T16, gft_dot4_32 for GF-T32). Four
// gft_mul64 (256-bit significand product) reduced by a 3-adder tree of the WIDE
// gft_add64 (128-bit significand sum) -- both realizations of the SAME specs the
// over-wire verifier runs. Same-sign accumulation. Combinational.
//
// GF-T64: bias 9841, offset_max 19682, mant_one 2^64. value = (1 + M/2^64) *
// 2^(offset - 9841). Operands packed as 4 x {offset(32b), mantissa(64b)} lanes:
// offset lane i is off[32*i +: 32], mantissa lane i is mant[64*i +: 64].
// ============================================================================
module gft_dot4_64 (
    input  wire [127:0] a_off,   // 4 lanes x 32b
    input  wire [255:0] a_mant,  // 4 lanes x 64b
    input  wire [127:0] b_off,
    input  wire [255:0] b_mant,
    output wire [31:0]  out_off,
    output wire [63:0]  out_mant
);
    wire [31:0] mo [0:3];
    wire [63:0] mm [0:3];
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : lane
            gft_mul64 #(.BIAS(32'd9841), .OFFSET_MAX(32'd19682), .MANT_ONE(128'h1_0000_0000_0000_0000)) u_mul (
                a_off[32*i +: 32], a_mant[64*i +: 64], b_off[32*i +: 32], b_mant[64*i +: 64],
                mo[i], mm[i]);
        end
    endgenerate

    // Reduction tree: (m0+m1) + (m2+m3), wide gft_add64.
    wire [31:0] s01o, s23o;
    wire [63:0] s01m, s23m;
    gft_add64 a01 (mo[0], mm[0], mo[1], mm[1], s01o, s01m);
    gft_add64 a23 (mo[2], mm[2], mo[3], mm[3], s23o, s23m);
    gft_add64 atop (s01o, s01m, s23o, s23m, out_off, out_mant);
endmodule
`default_nettype wire
