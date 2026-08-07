`timescale 1ns / 1ps
// GF-T8 dot2 KAT. Expected values are the COMPOSITION of the over-wire-verified
// gft_mul + gft_add stages at the small rung. GF-T8: mant_one 2^4 = 16, bias 13.
//   1.5   = (13, 8)   [ (1+8/16)*2^0 ]
//   1.5*1.5 = 2.25 = (14, 2)   [ (1+2/16)*2^1 ]
//   1.0   = (13, 0);  1.0*1.0 = (13, 0)
//   case A: both terms 1.5*1.5 -> (14,2)+(14,2) = (15, 2)   [ 4.5 ]
//   case B: 1.5*1.5 + 1.0*1.0 -> (14,2)+(13,0) = (14, 10)   [ 3.25 ]
module gft_dot2_8_kat_tb;
    reg [31:0] a1o,a1m,b1o,b1m,a2o,a2m,b2o,b2m;
    wire [31:0] oo, om;
    integer fails = 0;
    gft_dot2_8 dut (a1o,a1m,b1o,b1m,a2o,a2m,b2o,b2m, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [31:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, oo, om);
        end
    endtask
    initial begin
        // case A: 1.5*1.5 + 1.5*1.5 = 4.5
        a1o=13; a1m=8; b1o=13; b1m=8;  a2o=13; a2m=8; b2o=13; b2m=8;
        #1 chk("dot2_8 2x1.5^2", 15, 2);
        // case B: 1.5*1.5 + 1.0*1.0 = 3.25
        a1o=13; a1m=8; b1o=13; b1m=8;  a2o=13; a2m=0; b2o=13; b2m=0;
        #1 chk("dot2_8 1.5^2+1.0^2", 14, 10);
        if (fails==0) $display("KAT PASS: gft_dot2_8 = composition of over-wire-verified mul+add stages"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
