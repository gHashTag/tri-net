`timescale 1ns / 1ps
// GF-T subtract known-answer sweep -- values the over-wire verifier accepts:
//   GF-T16 2.0-1.0=1.0 : (41,0)-(40,0)     -> (40,0)
//   GF-T16 3.0-1.0=2.0 : (41,256)-(40,0)   -> (41,0)
//   GF-T8  1.5-0.5=1.0 : (13,8)-(12,0)     -> (13,0)   [wrong-rung asymmetric case]
//   GF-T8  2.0-1.0=1.0 : (14,0)-(13,0)     -> (13,0)
//   GF-T4  2.0-1.0=1.0 : (5,0)-(4,0)       -> (4,0)
module gft_sub_kat_tb;
    reg  [31:0] ao, am, bo, bm;
    wire [31:0] o16, m16, o8, m8, o4, m4;
    integer fails = 0;
    gft_sub                                       u16 (ao, am, bo, bm, o16, m16);
    gft_sub #(.MANT_ONE(16), .MANT_BITS(4)) u8  (ao, am, bo, bm, o8, m8);
    gft_sub #(.MANT_ONE(2),  .MANT_BITS(1)) u4  (ao, am, bo, bm, o4, m4);
    task chk(input [95:0] n, input [31:0] go, input [31:0] gm, input [31:0] eo, input [31:0] em);
        begin
            if (go !== eo || gm !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, go, gm, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, go, gm);
        end
    endtask
    initial begin
        ao=41; am=0;   bo=40; bm=0; #1 chk("T16 2-1",   o16, m16, 40, 0);
        ao=41; am=256; bo=40; bm=0; #1 chk("T16 3-1",   o16, m16, 41, 0);
        ao=13; am=8;   bo=12; bm=0; #1 chk("T8  1.5-.5", o8, m8, 13, 0);
        ao=14; am=0;   bo=13; bm=0; #1 chk("T8  2-1",    o8, m8, 13, 0);
        ao=5;  am=0;   bo=4;  bm=0; #1 chk("T4  2-1",    o4, m4,  4, 0);
        if (fails==0) $display("KAT PASS: gft_sub matches the over-wire verifier"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
