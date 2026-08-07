`timescale 1ns / 1ps
// GF-T64 dot2 KAT. Expected = composition of over-wire-verified gft_mul64 + gft_add64.
// GF-T64: mant_one 2^64, bias 9841. 1.5=(9841,2^63); 1.5*1.5=(9842,2^61); 1.0=(9841,0).
//   both 1.5*1.5 -> (9842,2^61)+(9842,2^61) = (9843, 2^61)          [ 4.5 ]
//   1.5^2 + 1.0^2 -> (9842,2^61)+(9841,0)   = (9842, 2^63 + 2^61)   [ 3.25 ]
module gft_dot2_64_kat_tb;
    reg  [31:0] a1o,b1o,a2o,b2o;
    reg  [63:0] a1m,b1m,a2m,b2m;
    wire [31:0] oo;
    wire [63:0] om;
    integer fails = 0;
    gft_dot2_64 dut (a1o,a1m,b1o,b1m,a2o,a2m,b2o,b2m, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [63:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,0x%h) exp (%0d,0x%h)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,0x%h)", n, oo, om);
        end
    endtask
    initial begin
        // both terms 1.5 * 1.5 -> 4.5
        a1o=9841; a1m=64'h8000000000000000; b1o=9841; b1m=64'h8000000000000000;
        a2o=9841; a2m=64'h8000000000000000; b2o=9841; b2m=64'h8000000000000000;
        #1 chk("dot2_64 2x1.5^2", 9843, 64'h2000000000000000); // (9843, 2^61)
        // 1.5*1.5 + 1.0*1.0 -> 3.25
        a2o=9841; a2m=64'd0; b2o=9841; b2m=64'd0;
        #1 chk("dot2_64 1.5^2+1.0^2", 9842, 64'hA000000000000000); // (9842, 2^63+2^61)
        if (fails==0) $display("KAT PASS: gft_dot2_64 = GF-T64 multiply-accumulate"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
