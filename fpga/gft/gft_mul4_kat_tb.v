`timescale 1ns / 1ps
// GF-T4 multiplier KAT. GF-T4: mant_one 2, bias 4, offset_max 8. Only two significands
// exist (M in {0,1} -> 1.0, 1.5), so products round TOWARD ZERO to the representable grid.
//   1.0 = (4,0);  1.5 = (4,1);  3.0 = (5,1);  (offset e means value * 2^(e-4))
//   1.0 * 1.0 = 1.0       -> (4,0)
//   1.0 * 1.5 = 1.5       -> (4,1)
//   1.5 * 1.5 = 2.25      -> 2.0   (RTZ: 2.25 not representable, floors to 1.0*2^1) -> (5,0)
//   3.0 * 3.0 = 9.0       -> 8.0   (RTZ) -> (7,0)
//   (7,1)*(7,1): 12*12=144 -> exponent overflows offset_max 8 (special row) -> out_off 8
module gft_mul4_kat_tb;
    reg  [31:0] ao, am, bo, bm;
    wire [31:0] oo, om;
    integer fails = 0;
    gft_mul4 dut (ao, am, bo, bm, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [31:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, oo, om);
        end
    endtask
    initial begin
        ao=4; am=0; bo=4; bm=0; #1 chk("1.0*1.0", 4, 0);
        ao=4; am=0; bo=4; bm=1; #1 chk("1.0*1.5", 4, 1);
        ao=4; am=1; bo=4; bm=1; #1 chk("1.5*1.5->2.0(RTZ)", 5, 0);
        ao=5; am=1; bo=5; bm=1; #1 chk("3.0*3.0->8.0(RTZ)", 7, 0);
        ao=7; am=1; bo=7; bm=1; #1 chk("(7,1)^2 -> exp saturates", 8, 0);
        if (fails==0) $display("KAT PASS: gft_mul4 = GF-T4 bottom rung (1-bit mantissa, RTZ)");
        else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
