`default_nettype none

// tern_corr_pn_tree -- the N=63 PN despreader with an explicit BALANCED adder
// tree instead of a flat accumulate. The flat version (tern_corr_pn_stream)
// sums 63 sign-selected terms as one chain -> ~63 adder-delays deep -> Fmax
// 3.87 MHz on xc7z020. Summing them as a binary tree makes the critical path
// log2(64) = 6 adder-delays, which is the fix the t27 SSOT `adder_tree_27`
// applies to the 27-wide dot. Same result, same zero DSP, far shorter path.
//
// SSOT for the ternary format: t27/specs/numeric/gfternary.t27.
module tern_corr_pn_tree #(
    parameter integer N    = 63,
    parameter integer W    = 16,
    parameter integer ACC  = 24,
    parameter integer AW   = 6
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              s_valid,
    input  wire signed [W-1:0] s_data,
    input  wire              c_wr,
    input  wire [AW-1:0]     c_addr,
    input  wire [1:0]        c_data,
    output reg               m_valid,
    output reg signed [ACC-1:0] m_data
);
    reg [1:0] tp [0:N-1];
    always @(posedge clk) if (c_wr) tp[c_addr] <= c_data;

    reg signed [W-1:0] xr [0:N-1];
    integer j;
    always @(posedge clk) begin
        if (rst) begin
            for (j = 0; j < N; j = j + 1) xr[j] <= 0;
        end else if (s_valid) begin
            for (j = N-1; j > 0; j = j - 1) xr[j] <= xr[j-1];
            xr[0] <= s_data;
        end
    end

    // sign-selected terms (pad to 64), each sign-extended to ACC
    wire signed [ACC-1:0] term [0:63];
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_term
            wire signed [ACC-1:0] sx = {{(ACC-W){xr[i][W-1]}}, xr[i]};
            assign term[i] = (tp[i] == 2'b01) ?  sx :
                             (tp[i] == 2'b10) ? -sx :
                                                 {ACC{1'b0}};
        end
        for (i = N; i < 64; i = i + 1) begin : g_pad
            assign term[i] = {ACC{1'b0}};
        end
    endgenerate

    // balanced binary reduction: 64 -> 32 -> 16 -> 8 -> 4 -> 2 -> 1
    wire signed [ACC-1:0] l1 [0:31], l2 [0:15], l3 [0:7], l4 [0:3], l5 [0:1];
    wire signed [ACC-1:0] corr;
    generate
        for (i = 0; i < 32; i = i + 1) begin : g1
            assign l1[i] = term[2*i] + term[2*i+1];
        end
        for (i = 0; i < 16; i = i + 1) begin : g2
            assign l2[i] = l1[2*i] + l1[2*i+1];
        end
        for (i = 0; i < 8; i = i + 1) begin : g3
            assign l3[i] = l2[2*i] + l2[2*i+1];
        end
        for (i = 0; i < 4; i = i + 1) begin : g4
            assign l4[i] = l3[2*i] + l3[2*i+1];
        end
        for (i = 0; i < 2; i = i + 1) begin : g5
            assign l5[i] = l4[2*i] + l4[2*i+1];
        end
    endgenerate
    assign corr = l5[0] + l5[1];

    always @(posedge clk) begin
        if (rst) begin m_valid <= 1'b0; m_data <= 0; end
        else begin m_valid <= s_valid; m_data <= corr; end
    end
endmodule

`default_nettype wire
