`timescale 1ns / 1ps
// gft_add_gen_kat_tb -- the AUTO spec->Verilog path for GF-T add.
//   t27c gen-verilog specs/tri_gft_add.t27 > /tmp/addgen.v
//   iverilog -g2012 -o /tmp/k.vvp /tmp/addgen.v fpga/gft/gft_add_gen_kat_tb.v && vvp /tmp/k.vvp
// The generated TriGftAdd.gft_add_*_c_p match the over-wire verifier: GF-T16
// 1.0+1.0 (40,0)+(40,0) -> (41,0); 1.0+0.5 (40,0)+(39,0) -> (40,256). (sig_bits=10)
module tb;
    reg clk = 0, rst_n = 1, en = 1; wire ready;
    TriGftAdd dut (.clk(clk), .rst_n(rst_n), .en(en), .ready(ready));
    integer f = 0;
    task ck(input [95:0] n, input [31:0] g, input [31:0] e);
        begin if (g !== e) begin $display("FAIL %0s: %0d exp %0d", n, g, e); f = f + 1; end else $display("ok %0s=%0d", n, g); end
    endtask
    initial begin
        ck("off_1+1",   dut.gft_add_offset_c_p(40, 40, 0, 0, 80, 512, 10), 41);
        ck("mant_1+1",  dut.gft_add_mant_c_p(40, 40, 0, 0, 512, 10), 0);
        ck("off_1+.5",  dut.gft_add_offset_c_p(40, 39, 0, 0, 80, 512, 10), 40);
        ck("mant_1+.5", dut.gft_add_mant_c_p(40, 39, 0, 0, 512, 10), 256);
        if (f == 0) $display("GEN-VERILOG ADD KAT PASS: generated GF-T add matches the over-wire verifier");
        else $display("GEN-VERILOG ADD KAT FAIL: %0d", f);
        $finish;
    end
endmodule
