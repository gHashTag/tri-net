`timescale 1ns / 1ps
`default_nettype none
// gft_mul32_tb -- iverilog KAT for the GF-T32 wide multiplier. Golden values are an
// independent oracle (integer significand product + value-domain cross-check). These
// products reach ~2^52, so they exercise the 64-bit datapath gft_mul.v cannot hold.
//   (364,0)^2                 = (364,0)          1 * 1     = 1
//   (364,2^24)^2              = (365,2^22)        1.5^2     = 2.25
//   (364,0)*(365,0)           = (365,0)           1 * 2     = 2
//   (400,2^23)^2              = (436,18874368)    (1.25*2^36)^2 = 1.5625*2^72
module gft_mul32_tb;
    reg  [31:0] a_off, a_mant, b_off, b_mant;
    wire [31:0] out_off, out_mant;
    integer errors = 0;

    gft_mul32 dut (.a_off(a_off), .a_mant(a_mant), .b_off(b_off), .b_mant(b_mant),
                   .out_off(out_off), .out_mant(out_mant));

    task check;
        input [31:0] oa, ma, ob, mb, eo, em;
        begin
            a_off=oa; a_mant=ma; b_off=ob; b_mant=mb;
            #1;
            if (out_off !== eo || out_mant !== em) begin
                $display("FAIL: (%0d,%0d)*(%0d,%0d) -> (%0d,%0d) expected (%0d,%0d)",
                         oa, ma, ob, mb, out_off, out_mant, eo, em);
                errors = errors + 1;
            end else $display("ok:   (%0d,%0d)*(%0d,%0d) -> (%0d,%0d)", oa, ma, ob, mb, out_off, out_mant);
        end
    endtask

    initial begin
        check(364, 0,        364, 0,        364, 0);           // 1 * 1 = 1
        check(364, 16777216, 364, 16777216, 365, 4194304);    // 1.5^2 = 2.25
        check(364, 0,        365, 0,        365, 0);           // 1 * 2 = 2
        check(400, 8388608,  400, 8388608,  436, 18874368);   // (1.25*2^36)^2
        if (errors == 0) $display("gft_mul32 KAT PASS");
        else $display("gft_mul32 KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
