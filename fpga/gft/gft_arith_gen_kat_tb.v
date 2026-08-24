`timescale 1ns / 1ps
// gft_arith_gen_kat_tb -- proves the AUTO spec->Verilog path: `t27c gen-verilog
// specs/tri_gft_arith.t27` emits the TriGftArith module whose gft_mul functions produce
// the EXACT results the over-wire verifier accepts. So ONE .t27 generates BOTH the Rust
// A2A verifier AND synthesizable Verilog, and they agree. Requires the generated module:
//   t27c gen-verilog specs/tri_gft_arith.t27 > /tmp/gftgen.v
//   iverilog -g2012 -o /tmp/k.vvp /tmp/gftgen.v fpga/gft/gft_arith_gen_kat_tb.v && vvp /tmp/k.vvp
// (t27c gen-verilog interleaved-reg defect fixed upstream; this is the regression gate.)
module tb;
    reg clk = 0, rst_n = 1, en = 1; wire ready;
    TriGftArith dut (.clk(clk), .rst_n(rst_n), .en(en), .ready(ready));
    integer f = 0;
    task ck(input [95:0] n, input [31:0] g, input [31:0] e);
        begin if (g !== e) begin $display("FAIL %0s: %0d exp %0d", n, g, e); f = f + 1; end else $display("ok %0s=%0d", n, g); end
    endtask
    initial begin
        // GF-T16 1.5*1.5 -> (off 43, mant 64); phi^2 (41,0)^2 -> (off 42, mant 0).
        ck("off_1.5",  dut.gft_mul_offset_full_p(41, 256, 41, 256, 40, 80, 512), 43);
        ck("mant_1.5", dut.gft_mul_mant_p(256, 256, 512), 64);
        ck("off_phi2", dut.gft_mul_offset_full_p(41, 0, 41, 0, 40, 80, 512), 42);
        ck("mant_phi2", dut.gft_mul_mant_p(0, 0, 512), 0);
        if (f == 0) $display("GEN-VERILOG KAT PASS: generated GF-T Verilog matches the over-wire verifier");
        else $display("GEN-VERILOG KAT FAIL: %0d", f);
        $finish;
    end
endmodule
