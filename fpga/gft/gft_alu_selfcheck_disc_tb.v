`timescale 1ns / 1ps
// Discrimination check for the on-chip self-test: prove the fail path WORKS.
// Compile with -DGFT_SELFCHECK_FAULT to corrupt one expected value; the checker
// must raise `fail` (not `pass`). Without the define the same design PASSes
// (proven in gft_alu_selfcheck's own tb). A checker that cannot fail is worthless.
module gft_alu_selfcheck_disc_tb;
    reg clk=0, rst_n=0; wire pass, fail;
    gft_alu_selfcheck dut(clk, rst_n, pass, fail);
    always #5 clk = ~clk;
    initial begin
        #12 rst_n=1;
        repeat (40) @(posedge clk);
`ifdef GFT_SELFCHECK_FAULT
        if (fail && !pass) $display("DISCRIMINATION PASS: a corrupted vector raised fail (checker catches wrong answers)");
        else $display("DISCRIMINATION FAIL: fault not caught (pass=%b fail=%b)", pass, fail);
`else
        if (pass && !fail) $display("GOLDEN PASS: uncorrupted vectors -> pass");
        else $display("GOLDEN FAIL: pass=%b fail=%b", pass, fail);
`endif
        $finish;
    end
endmodule
