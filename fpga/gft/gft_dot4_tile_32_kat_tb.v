`timescale 1ns / 1ps
// GF-T32 dot4 tile KAT. Same golden results as gft_dot4_32, through the narrow packed
// ports (10-bit offset + 25-bit mantissa per lane). GF-T32: mant_one 2^25, bias 364.
//   1.5 = (364, 16777216);  1.5*1.5 = (365, 4194304);  1.0 = (364, 0)
//   case A: four lanes 1.5*1.5 -> (367, 4194304) = 9.0
//   case B: lanes {1.5^2, 1.0^2, 1.5^2, 1.0^2} -> (366, 20971520) = 6.5
module gft_dot4_tile_32_kat_tb;
    reg  [39:0] aoff, boff;
    reg  [99:0] amant, bmant;
    wire [9:0]  oo;
    wire [24:0] om;
    integer fails = 0;
    gft_dot4_tile_32 dut (aoff, amant, boff, bmant, oo, om);
    task chk(input [95:0] n, input [9:0] eo, input [24:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, oo, om);
        end
    endtask
    initial begin
        // case A: all lanes 1.5 * 1.5 -> 9.0
        aoff  = {10'd364,10'd364,10'd364,10'd364}; amant = {25'd16777216,25'd16777216,25'd16777216,25'd16777216};
        boff  = {10'd364,10'd364,10'd364,10'd364}; bmant = {25'd16777216,25'd16777216,25'd16777216,25'd16777216};
        #1 chk("tile32 4x1.5^2", 367, 4194304);
        // case B: lanes 1.5,1.0,1.5,1.0 (each squared) -> 6.5
        amant = {25'd16777216,25'd0,25'd16777216,25'd0}; bmant = {25'd16777216,25'd0,25'd16777216,25'd0};
        #1 chk("tile32 mixed 1.5/1.0", 366, 20971520);
        if (fails==0) $display("KAT PASS: gft_dot4_tile_32 = packed-port GF-T32 dot4, golden results"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
