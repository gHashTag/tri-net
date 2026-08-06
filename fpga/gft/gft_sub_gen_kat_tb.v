`timescale 1ns / 1ps
// gft_sub_gen_kat_tb -- the AUTO spec->Verilog path for GF-T subtract.
//   t27c gen-verilog specs/tri_gft_sub.t27 > /tmp/subgen.v
//   iverilog -g2012 -o /tmp/k.vvp /tmp/subgen.v fpga/gft/gft_sub_gen_kat_tb.v && vvp /tmp/k.vvp
// The generated TriGftSub.gft_sub_*_c_p match the over-wire verifier: GF-T16
// 2.0-1.0 (41,0)-(40,0) -> (40,0). (mant_one 512, mant_bits 9)
module tb;
    reg clk = 0, rst_n = 1, en = 1; wire ready;
    TriGftSub dut (.clk(clk), .rst_n(rst_n), .en(en), .ready(ready));
    integer f = 0;
    task ck(input [95:0] n, input [31:0] g, input [31:0] e);
        begin if (g !== e) begin $display("FAIL %0s: %0d exp %0d", n, g, e); f = f + 1; end else $display("ok %0s=%0d", n, g); end
    endtask
    initial begin
        ck("off_2-1",  dut.gft_sub_offset_c_p(41, 40, 0, 0, 512, 9), 40);
        ck("mant_2-1", dut.gft_sub_mant_c_p(41, 40, 0, 0, 512, 9), 0);
        if (f == 0) $display("GEN-VERILOG SUB KAT PASS: generated GF-T sub matches the over-wire verifier");
        else $display("GEN-VERILOG SUB KAT FAIL: %0d", f);
        $finish;
    end
endmodule
