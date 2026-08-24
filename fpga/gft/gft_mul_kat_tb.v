`timescale 1ns / 1ps
// Known-answer sweep for gft_mul, per rung. The expected values are the exact
// results the over-wire verifier accepts (trinet_rung_verify / _compute_over_mesh):
//   GF-T16 phi^1*phi^1 = phi^2 : (41,0)*(41,0)     -> (42, 0)
//   GF-T16 1.5*1.5             : (41,256)*(41,256) -> (43, 64)
//   GF-T8  1.5*1.5             : (13,8)*(13,8)     -> (14, 2)
//   GF-T4  1.5*1.5             : (4,1)*(4,1)       -> (5, 0)
module gft_mul_kat_tb;
    reg  [31:0] ao, am, bo, bm;
    wire [31:0] o16, m16, o8, m8, o4, m4;
    integer fails = 0;

    gft_mul                                    u16 (ao, am, bo, bm, o16, m16);
    gft_mul #(.BIAS(13), .OFFSET_MAX(26), .MANT_ONE(16)) u8 (ao, am, bo, bm, o8, m8);
    gft_mul #(.BIAS(4),  .OFFSET_MAX(8),  .MANT_ONE(2))  u4 (ao, am, bo, bm, o4, m4);

    task chk(input [127:0] name, input [31:0] got_o, input [31:0] got_m, input [31:0] exp_o, input [31:0] exp_m);
        begin
            if (got_o !== exp_o || got_m !== exp_m) begin
                $display("FAIL %0s: got (%0d,%0d) exp (%0d,%0d)", name, got_o, got_m, exp_o, exp_m);
                fails = fails + 1;
            end else $display("ok   %0s: (%0d,%0d)", name, got_o, got_m);
        end
    endtask

    initial begin
        ao=41; am=0;   bo=41; bm=0;   #1 chk("GFT16 phi2", o16, m16, 42, 0);
        ao=41; am=256; bo=41; bm=256; #1 chk("GFT16 1.5x1.5", o16, m16, 43, 64);
        ao=13; am=8;   bo=13; bm=8;   #1 chk("GFT8  1.5x1.5", o8,  m8,  14, 2);
        ao=4;  am=1;   bo=4;  bm=1;   #1 chk("GFT4  1.5x1.5", o4,  m4,  5,  0);
        if (fails == 0) $display("KAT PASS: gft_mul matches the over-wire verifier on all rungs");
        else $display("KAT FAIL: %0d mismatches", fails);
        $finish;
    end
endmodule
