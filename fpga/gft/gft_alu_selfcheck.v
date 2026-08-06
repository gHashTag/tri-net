`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_alu_selfcheck -- on-chip GF-T ALU self-test, for flashing to the AX7203.
// Walks a ROM of known-answer vectors (the EXACT values the over-wire verifier
// accepts) through gft_alu; `pass` (an LED) asserts iff every vector matched and
// the sweep finished, `fail` asserts on any mismatch. This is the flashable proof
// that GF-T mul/add/sub run on real silicon.
// ============================================================================
module gft_alu_selfcheck (
    input  wire clk,
    input  wire rst_n,
    output reg  pass,
    output reg  fail
);
    localparam N = 6;
    reg [1:0]  op   [0:N-1];
    reg [31:0] aoff [0:N-1], amant [0:N-1], boff [0:N-1], bmant [0:N-1];
    reg [31:0] eoff [0:N-1], emant [0:N-1];
    integer k;
    initial begin
        // op 0=add 1=mul 2=sub. GF-T16 vectors, expected = over-wire results.
        op[0]=1; aoff[0]=41; amant[0]=0;   boff[0]=41; bmant[0]=0;   eoff[0]=42; emant[0]=0;    // MUL phi^2
        op[1]=1; aoff[1]=41; amant[1]=256; boff[1]=41; bmant[1]=256; eoff[1]=43; emant[1]=64;   // MUL 1.5x1.5
        op[2]=0; aoff[2]=40; amant[2]=0;   boff[2]=40; bmant[2]=0;   eoff[2]=41; emant[2]=0;    // ADD 1+1
        op[3]=0; aoff[3]=40; amant[3]=0;   boff[3]=39; bmant[3]=0;   eoff[3]=40; emant[3]=256;  // ADD 1+0.5
        op[4]=2; aoff[4]=41; amant[4]=0;   boff[4]=40; bmant[4]=0;   eoff[4]=40; emant[4]=0;    // SUB 2-1
        op[5]=2; aoff[5]=41; amant[5]=256; boff[5]=40; bmant[5]=0;   eoff[5]=41; emant[5]=0;    // SUB 3-1
    end

    reg [3:0] idx;
    wire [31:0] oo, om;
    gft_alu dut (op[idx], aoff[idx], amant[idx], boff[idx], bmant[idx], oo, om);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx <= 0; pass <= 0; fail <= 0;
        end else if (!pass && !fail) begin
            if (oo !== eoff[idx] || om !== emant[idx]) fail <= 1;
            else if (idx == N-1) pass <= 1;
            else idx <= idx + 1;
        end
    end
endmodule
`default_nettype wire
