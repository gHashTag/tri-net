`timescale 1ns / 1ps
// GF-T4 dot2 KAT. Composition of the over-wire-verified gft_mul4 + gft_add at the bottom
// rung. GF-T4: mant_one 2, bias 4. 1.0=(4,0); 1.5=(4,1); 1.5*1.5=2.25->2.0 RTZ=(5,0).
//   both 1.5*1.5 -> (5,0)+(5,0) = 4.0 -> (6,0)
//   1.5^2 + 1.0^2 -> (5,0)+(4,0) = 3.0 -> (5,1)
module gft_dot2_4_kat_tb;
    reg  [31:0] a1o,a1m,b1o,b1m,a2o,a2m,b2o,b2m;
    wire [31:0] oo, om;
    integer fails = 0;
    gft_dot2_4 dut (a1o,a1m,b1o,b1m,a2o,a2m,b2o,b2m, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [31:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, oo, om);
        end
    endtask
    initial begin
        // both terms 1.5*1.5 -> 4.0
        a1o=4; a1m=1; b1o=4; b1m=1;  a2o=4; a2m=1; b2o=4; b2m=1;
        #1 chk("dot2_4 2x1.5^2", 6, 0);
        // 1.5*1.5 + 1.0*1.0 -> 3.0
        a1o=4; a1m=1; b1o=4; b1m=1;  a2o=4; a2m=0; b2o=4; b2m=0;
        #1 chk("dot2_4 1.5^2+1.0^2", 5, 1);
        if (fails==0) $display("KAT PASS: gft_dot2_4 = GF-T4 bottom-rung MAC");
        else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
