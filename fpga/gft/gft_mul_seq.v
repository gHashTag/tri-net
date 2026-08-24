`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul_seq -- valid/ready handshake wrapper around the combinational gft_mul,
// with GF-T16 pack/unpack. Drop-in for gf_mul_param in the proven ax7203 UART
// top: same port shape (clk/rst/in_valid/in_a/in_b/in_ready/out_valid/out_y/
// out_ready), 16-bit packed operands, 1-cycle latency.
//
// GF-T16 wire layout (magnitude): [ offset : bits 15..9 (7b) | mant : bits 8..0 (9b) ].
// value = (1 + mant/512) * 2^(offset-40). Sign is a separate 17th bit and is not
// carried on this 16-bit datapath (the silicon demo multiplies magnitudes, exactly
// like the gf16_mul bring-up it mirrors).
// ============================================================================
module gft_mul_seq (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    input  wire [15:0] in_a,
    input  wire [15:0] in_b,
    output wire        in_ready,
    output reg         out_valid,
    output reg  [15:0] out_y,
    input  wire        out_ready
);
    // Unpack the 16-bit magnitude into the (offset, mant) pair gft_mul expects.
    wire [31:0] a_off  = {25'd0, in_a[15:9]};
    wire [31:0] a_mant = {23'd0, in_a[8:0]};
    wire [31:0] b_off  = {25'd0, in_b[15:9]};
    wire [31:0] b_mant = {23'd0, in_b[8:0]};

    wire [31:0] o_off, o_mant;
    gft_mul #(.BIAS(40), .OFFSET_MAX(80), .MANT_ONE(512)) u_mul (
        .a_off(a_off), .a_mant(a_mant), .b_off(b_off), .b_mant(b_mant),
        .out_off(o_off), .out_mant(o_mant)
    );

    // Repack: offset in the top 7 bits, mantissa in the low 9.
    wire [15:0] y_packed = {o_off[6:0], o_mant[8:0]};

    // Accept a new operand pair whenever we are not holding an unconsumed result.
    assign in_ready = ~out_valid | out_ready;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_y     <= 16'd0;
        end else begin
            if (in_valid & in_ready) begin
                out_y     <= y_packed;   // gft_mul is combinational: y_packed is valid now
                out_valid <= 1'b1;
            end else if (out_valid & out_ready) begin
                out_valid <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire
