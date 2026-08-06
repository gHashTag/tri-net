`timescale 1ns / 1ps
// GF-T add known-answer sweep -- values the over-wire verifier accepts (trinet_rung_verify):
//   GF-T16 1.0+1.0=2.0 : (40,0)+(40,0) -> (41,0)
//   GF-T16 1.0+0.5=1.5 : (40,0)+(39,0) -> (40,256)
//   GF-T8  1.0+1.0=2.0 : (13,0)+(13,0) -> (14,0)
//   GF-T8  1.0+0.5=1.5 : (13,0)+(12,0) -> (13,8)   [the wrong-rung asymmetric case]
module gft_add_kat_tb;
    reg  [31:0] ao, am, bo, bm;
    wire [31:0] o16, m16, o8, m8;
    integer fails = 0;
    gft_add                                                  u16 (ao, am, bo, bm, o16, m16);
    gft_add #(.OFFSET_MAX(26), .MANT_ONE(16), .SIG_BITS(5)) u8  (ao, am, bo, bm, o8,  m8);
    task chk(input [95:0] n, input [31:0] go, input [31:0] gm, input [31:0] eo, input [31:0] em);
        begin
            if (go !== eo || gm !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, go, gm, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, go, gm);
        end
    endtask
    initial begin
        ao=40; am=0; bo=40; bm=0; #1 chk("T16 1+1",   o16, m16, 41, 0);
        ao=40; am=0; bo=39; bm=0; #1 chk("T16 1+0.5", o16, m16, 40, 256);
        ao=13; am=0; bo=13; bm=0; #1 chk("T8  1+1",   o8,  m8,  14, 0);
        ao=13; am=0; bo=12; bm=0; #1 chk("T8  1+0.5", o8,  m8,  13, 8);
        if (fails==0) $display("KAT PASS: gft_add matches the over-wire verifier"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
