`timescale 1ns / 1ps
`default_nettype none
// gft_dot2_32_tb -- iverilog KAT for the GF-T32 MAC. Golden values from the exact integer
// oracle (gft_mul32 products + gft_add sum), value-domain cross-checked.
//   (364,2^24)^2 + (364,0)^2 = 2.25 + 1.0 = 3.25 -> (365, 5*2^22 = 20971520)
//   (364,0)^2    + (364,0)^2 = 1.0  + 1.0 = 2.0  -> (365, 0)
module gft_dot2_32_tb;
    reg  [31:0] a1o,a1m,b1o,b1m,a2o,a2m,b2o,b2m;
    wire [31:0] oo, om;
    integer errors = 0;

    gft_dot2_32 dut (.a1_off(a1o),.a1_mant(a1m),.b1_off(b1o),.b1_mant(b1m),
                     .a2_off(a2o),.a2_mant(a2m),.b2_off(b2o),.b2_mant(b2m),
                     .out_off(oo),.out_mant(om));

    task chk;
        input [31:0] eo, em; input [255:0] name;
        begin
            #1;
            if (oo !== eo || om !== em) begin
                $display("FAIL %0s: (%0d,%0d) want (%0d,%0d)", name, oo, om, eo, em); errors=errors+1;
            end else $display("ok:   %0s -> (%0d,%0d)", name, oo, om);
        end
    endtask

    initial begin
        // term operands: (364,2^24)=1.5, (364,0)=1.0
        // dot: (364,2^24)^2 + (364,0)^2
        a1o=364; a1m=16777216; b1o=364; b1m=16777216;  // 1.5*1.5 = 2.25 -> (365,2^22)
        a2o=364; a2m=0;        b2o=364; b2m=0;          // 1.0*1.0 = 1.0  -> (364,0)
        chk(32'd365, 32'd20971520, "1.5^2 + 1 = 3.25");  // 5*2^22

        a1o=364; a1m=0; b1o=364; b1m=0;
        a2o=364; a2m=0; b2o=364; b2m=0;
        chk(32'd365, 32'd0, "1 + 1 = 2");

        if (errors == 0) $display("gft_dot2_32 KAT PASS");
        else $display("gft_dot2_32 KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
