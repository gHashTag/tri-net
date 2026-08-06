`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_macc -- streaming GF-T16 multiply-accumulate: a running dot product of
// arbitrary length. Each accepted (a,b) folds a*b into the accumulator; `first`
// starts a fresh sum. This is the matmul ROW primitive -- dot2 unrolled into a
// stream, so an N-length dot product costs N cycles and 1 mul + 1 add of area
// (vs dot2/dot4's parallel-tree area). Reuses the silicon-proven gft_mul + gft_add.
//
// acc(0)          = a0*b0           (when first=1)
// acc(k) [k>0]    = acc(k-1) + ak*bk
//
// Operands/acc are packed GF-T16 magnitudes [ offset:15..9 | mant:8..0 ].
// ============================================================================
module gft_macc (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,  // fold (a,b) this cycle
    input  wire        first,     // 1 = start new accumulation (acc <- a*b)
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] acc
);
    // product a*b (combinational gft_mul on the unpacked operands)
    wire [31:0] p_off, p_mant;
    gft_mul #(.BIAS(40), .OFFSET_MAX(80), .MANT_ONE(512)) u_mul (
        .a_off({25'd0, a[15:9]}), .a_mant({23'd0, a[8:0]}),
        .b_off({25'd0, b[15:9]}), .b_mant({23'd0, b[8:0]}),
        .out_off(p_off), .out_mant(p_mant));
    wire [15:0] prod = {p_off[6:0], p_mant[8:0]};

    // acc + product (combinational gft_add)
    wire [31:0] s_off, s_mant;
    gft_add #(.OFFSET_MAX(80), .MANT_ONE(512), .SIG_BITS(10)) u_add (
        .a_off({25'd0, acc[15:9]}), .a_mant({23'd0, acc[8:0]}),
        .b_off(p_off), .b_mant(p_mant),
        .out_off(s_off), .out_mant(s_mant));
    wire [15:0] sum = {s_off[6:0], s_mant[8:0]};

    always @(posedge clk or posedge rst) begin
        if (rst) acc <= 16'd0;
        else if (in_valid) acc <= first ? prod : sum;
    end
endmodule
`default_nettype wire
