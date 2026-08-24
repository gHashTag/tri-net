`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_alu -- the GF-T arithmetic unit: mul / add / sub selected by `op`.
// Muxes gft_mul + gft_add + gft_sub (realizations of specs/tri_gft_{arith,add,sub}.t27,
// the SAME specs the over-wire verifier runs). Combinational; GF-T16 by default.
//   op = 0 -> add, 1 -> mul, 2 -> sub  (sub = different-sign magnitude difference).
// ============================================================================
module gft_alu #(
    parameter [31:0] BIAS       = 40,
    parameter [31:0] OFFSET_MAX = 80,
    parameter [31:0] MANT_ONE   = 512,
    parameter [31:0] MANT_BITS  = 9,
    parameter [31:0] ALIGN_CAP  = 22
) (
    input  wire [1:0]  op,
    input  wire [31:0] a_off,
    input  wire [31:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [31:0] b_mant,
    output wire [31:0] out_off,
    output wire [31:0] out_mant
);
    localparam [1:0] OP_ADD = 2'd0, OP_MUL = 2'd1, OP_SUB = 2'd2;
    localparam [31:0] SIG_BITS = MANT_BITS + 1;

    wire [31:0] mo, mm, ao, am, so, sm;
    gft_mul #(.BIAS(BIAS), .OFFSET_MAX(OFFSET_MAX), .MANT_ONE(MANT_ONE))       u_mul (a_off, a_mant, b_off, b_mant, mo, mm);
    gft_add #(.OFFSET_MAX(OFFSET_MAX), .MANT_ONE(MANT_ONE), .SIG_BITS(SIG_BITS)) u_add (a_off, a_mant, b_off, b_mant, ao, am);
    gft_sub #(.MANT_ONE(MANT_ONE), .MANT_BITS(MANT_BITS), .ALIGN_CAP(ALIGN_CAP)) u_sub (a_off, a_mant, b_off, b_mant, so, sm);

    assign out_off  = (op == OP_MUL) ? mo : (op == OP_SUB) ? so : ao;
    assign out_mant = (op == OP_MUL) ? mm : (op == OP_SUB) ? sm : am;
endmodule
`default_nettype wire
