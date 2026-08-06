`timescale 1ns / 1ps
// GF-T64 dot4 KAT. Expected = composition of over-wire-verified gft_mul64 + gft_add64.
// GF-T64: mant_one 2^64, bias 9841. 1.5=(9841,2^63); 1.5*1.5=(9842,2^61); 1.0=(9841,0).
//   case A: four lanes 1.5*1.5 -> ((p+p)+(p+p)), p=(9842,2^61)
//           (9842,2^61)+(9842,2^61)=(9843,2^61) twice -> (9844, 2^61) = 9.0
//   case B: lanes {1.5^2, 1.0^2, 1.5^2, 1.0^2}:
//           (9842,2^61)+(9841,0)=(9842, 2^63+2^61) twice -> (9843, 2^63+2^61) = 6.5
module gft_dot4_64_kat_tb;
    reg  [127:0] aoff, boff;
    reg  [255:0] amant, bmant;
    wire [31:0]  oo;
    wire [63:0]  om;
    integer fails = 0;
    gft_dot4_64 dut (aoff, amant, boff, bmant, oo, om);
    task chk(input [95:0] n, input [31:0] eo, input [63:0] em);
        begin
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d,0x%h) exp (%0d,0x%h)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d,0x%h)", n, oo, om);
        end
    endtask
    initial begin
        // case A: all lanes 1.5 * 1.5 -> 9.0
        aoff  = {32'd9841,32'd9841,32'd9841,32'd9841};
        amant = {64'h8000000000000000,64'h8000000000000000,64'h8000000000000000,64'h8000000000000000};
        boff  = aoff; bmant = amant;
        #1 chk("dot4_64 4x1.5^2", 9844, 64'h2000000000000000); // (9844, 2^61)
        // case B: lanes 1.5,1.0,1.5,1.0 (each squared) -> 6.5
        amant = {64'h8000000000000000,64'd0,64'h8000000000000000,64'd0};
        bmant = amant;
        #1 chk("dot4_64 mixed 1.5/1.0", 9843, 64'hA000000000000000); // (9843, 2^63+2^61)
        if (fails==0) $display("KAT PASS: gft_dot4_64 = 4-lane GF-T64 MAC (mul64 + add64 tree)"); else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
