`timescale 1ns / 1ps
// GF-T32 dot4 KAT. Expected values are the COMPOSITION of the over-wire-verified
// gft_mul32 + gft_add stages (verifies the 4-lane reduction wiring at the top rung).
// GF-T32: mant_one 2^25 = 33554432, bias 364.
//   1.5   = (364, 16777216)   [ (1+2^24/2^25)*2^0 ]
//   1.5*1.5 = 2.25 = (365, 4194304)   [ (1+1/8)*2^1, mant 2^22 ]
//   1.0   = (364, 0);  1.0*1.0 = (364, 0)
//   case A: all four lanes 1.5*1.5 -> ((365,m)+(365,m)) twice = (366,m) twice
//           -> (367, 4194304)   [ 9.0 = (1+1/8)*2^3 ]
//   case B: lanes {1.5^2, 1.0^2, 1.5^2, 1.0^2}:
//           (365,4194304)+(364,0) = (365, 20971520)  [ 3.25 ]  (twice)
//           (365,20971520)+(365,20971520) = (366, 20971520)  [ 6.5 ]
module gft_dot4_32_kat_tb;
    reg [127:0] aoff, amant, boff, bmant;
    wire [31:0] oo, om;
    integer fails = 0;
    gft_dot4_32 dut (aoff, amant, boff, bmant, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [31:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, oo, om);
        end
    endtask
    initial begin
        // case A: all lanes 1.5 * 1.5 -> dot = 9.0
        aoff  = {32'd364,32'd364,32'd364,32'd364}; amant = {32'd16777216,32'd16777216,32'd16777216,32'd16777216};
        boff  = {32'd364,32'd364,32'd364,32'd364}; bmant = {32'd16777216,32'd16777216,32'd16777216,32'd16777216};
        #1 chk("dot4_32 4x1.5^2", 367, 4194304);
        // case B: lanes 1.5, 1.0, 1.5, 1.0  (each squared) -> dot = 6.5
        aoff  = {32'd364,32'd364,32'd364,32'd364}; amant = {32'd16777216,32'd0,32'd16777216,32'd0};
        boff  = {32'd364,32'd364,32'd364,32'd364}; bmant = {32'd16777216,32'd0,32'd16777216,32'd0};
        #1 chk("dot4_32 mixed 1.5/1.0", 366, 20971520);
        if (fails==0) $display("KAT PASS: gft_dot4_32 = composition of over-wire-verified mul32+add stages"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
