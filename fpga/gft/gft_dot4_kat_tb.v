`timescale 1ns / 1ps
// GF-T dot4 KAT. Expected values are the COMPOSITION of the individually
// over-wire-verified gft_mul and gft_add stages (verifies the dot wiring):
//   all four lanes (41,256)*(41,256)=(43,64): dot = ((43,64)+(43,64))+((43,64)+(43,64))
//     = (44,64)+(44,64) = (45,64)
//   lanes {1.5x1.5, phi^2, 1.5x1.5, phi^2} = {(43,64),(42,0),(43,64),(42,0)}:
//     ((43,64)+(42,0)) + ((43,64)+(42,0)) = (43,320)+(43,320) = (44,320)
module gft_dot4_kat_tb;
    reg [127:0] aoff, amant, boff, bmant;
    wire [31:0] oo, om;
    integer fails = 0;
    gft_dot4 dut (aoff, amant, boff, bmant, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [31:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,%0d) exp (%0d,%0d)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,%0d)", n, oo, om);
        end
    endtask
    initial begin
        // all lanes 1.5*1.5 -> (43,64); sum of 4 -> (45,64)
        aoff  = {32'd41,32'd41,32'd41,32'd41}; amant = {32'd256,32'd256,32'd256,32'd256};
        boff  = {32'd41,32'd41,32'd41,32'd41}; bmant = {32'd256,32'd256,32'd256,32'd256};
        #1 chk("dot4 4x1.5^2", 45, 64);
        // lanes: 1.5^2, phi^2, 1.5^2, phi^2  (mant 256/0 alternating)
        amant = {32'd256,32'd0,32'd256,32'd0}; bmant = {32'd256,32'd0,32'd256,32'd0};
        #1 chk("dot4 mixed", 44, 320);
        if (fails==0) $display("KAT PASS: gft_dot4 = composition of over-wire-verified mul+add stages"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
