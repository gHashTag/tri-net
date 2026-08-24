`timescale 1ns / 1ps
// GF-T16 known-answer check for the narrowed wrapper -- same values the over-wire
// verifier accepts: phi^1*phi^1=phi^2 (41,0)^2 -> (42,0); 1.5*1.5 (41,256)^2 -> (43,64).
module gft16_mul_kat_tb;
    reg  [6:0] ao, bo; reg [8:0] am, bm;
    wire [6:0] oo; wire [8:0] om;
    integer fails = 0;
    gft16_mul u (ao, am, bo, bm, oo, om);
    task chk(input [63:0] n, input [6:0] go, input [8:0] gm, input [6:0] eo, input [8:0] em);
        begin
            if (go !== eo || gm !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, go, gm, eo, em); fails = fails + 1; end
            else $display("ok   %0s: (%0d,%0d)", n, go, gm);
        end
    endtask
    initial begin
        ao=41; am=0;   bo=41; bm=0;   #1 chk("phi2",    oo, om, 42, 0);
        ao=41; am=256; bo=41; bm=256; #1 chk("1.5x1.5", oo, om, 43, 64);
        if (fails==0) $display("KAT PASS: gft16_mul (narrow) matches the over-wire verifier"); else $display("KAT FAIL");
        $finish;
    end
endmodule
