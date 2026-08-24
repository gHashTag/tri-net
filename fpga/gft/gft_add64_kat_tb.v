`timescale 1ns / 1ps
// GF-T64 wide adder KAT. GF-T64: mant_one 2^64, bias 9841.
//   1.5 = (9841, 2^63);  1.0 = (9841, 0)
//   1.5 + 1.5 = 3.0 = (9842, 2^63)   [ (1 + 2^63/2^64)*2^1 ]
//   1.5 + 1.0 = 2.5 = (9842, 2^62)   [ (1 + 2^62/2^64)*2^1 ]
module gft_add64_kat_tb;
    reg  [31:0] aoff, boff;
    reg  [63:0] amant, bmant;
    wire [31:0] oo;
    wire [63:0] om;
    integer fails = 0;
    gft_add64 dut (aoff, amant, boff, bmant, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [63:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,0x%h) exp (%0d,0x%h)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,0x%h)", n, oo, om);
        end
    endtask
    initial begin
        aoff=9841; amant=64'h8000000000000000; boff=9841; bmant=64'h8000000000000000;
        #1 chk("add64 1.5+1.5", 9842, 64'h8000000000000000); // (9842, 2^63)
        aoff=9841; amant=64'h8000000000000000; boff=9841; bmant=64'd0;
        #1 chk("add64 1.5+1.0", 9842, 64'h4000000000000000); // (9842, 2^62)
        if (fails==0) $display("KAT PASS: gft_add64 = 128-bit GF-T64 same-sign add"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
