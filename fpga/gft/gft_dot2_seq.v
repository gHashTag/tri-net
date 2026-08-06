`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot2_seq -- valid/ready handshake wrapper around the combinational gft_dot2
// (2-term GF-T16 MAC). Same shape as gft_mul_seq but four 16-bit packed operands
// in, one 16-bit packed result out; 1-cycle latency. Feeds the ax7203 UART top.
// ============================================================================
module gft_dot2_seq (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    input  wire [15:0] a1,
    input  wire [15:0] b1,
    input  wire [15:0] a2,
    input  wire [15:0] b2,
    output wire        in_ready,
    output reg         out_valid,
    output reg  [15:0] out_y,
    input  wire        out_ready
);
    wire [15:0] y_comb;
    gft_dot2 u_dot2 (.a1(a1), .b1(b1), .a2(a2), .b2(b2), .y(y_comb));

    assign in_ready = ~out_valid | out_ready;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_y     <= 16'd0;
        end else begin
            if (in_valid & in_ready) begin
                out_y     <= y_comb;   // gft_dot2 is combinational: y_comb is valid now
                out_valid <= 1'b1;
            end else if (out_valid & out_ready) begin
                out_valid <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire
