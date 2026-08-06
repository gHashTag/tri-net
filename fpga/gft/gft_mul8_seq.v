`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul8_seq -- valid/ready wrapper around gft_mul at the GF-T8 rung, the compact
// edge rung. Same shape as gft_mul_seq (16-bit ports) but the packed magnitude is
// GF-T8: [ offset : bits 8..4 (5b) | mant : bits 3..0 (4b) ] = 9 bits, value
// (1 + mant/16) * 2^(offset-13). Feeds the proven ax7203 UART top unchanged.
// ============================================================================
module gft_mul8_seq (
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
    // GF-T8 unpack: offset = bits 8..4 (5b), mant = bits 3..0 (4b).
    wire [31:0] a_off  = {27'd0, in_a[8:4]};
    wire [31:0] a_mant = {28'd0, in_a[3:0]};
    wire [31:0] b_off  = {27'd0, in_b[8:4]};
    wire [31:0] b_mant = {28'd0, in_b[3:0]};

    wire [31:0] o_off, o_mant;
    gft_mul #(.BIAS(13), .OFFSET_MAX(26), .MANT_ONE(16)) u_mul (
        .a_off(a_off), .a_mant(a_mant), .b_off(b_off), .b_mant(b_mant),
        .out_off(o_off), .out_mant(o_mant));

    wire [15:0] y_packed = {7'd0, o_off[4:0], o_mant[3:0]};

    assign in_ready = ~out_valid | out_ready;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_y     <= 16'd0;
        end else begin
            if (in_valid & in_ready) begin
                out_y     <= y_packed;
                out_valid <= 1'b1;
            end else if (out_valid & out_ready) begin
                out_valid <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire
