`timescale 1ns / 1ps
`default_nettype none
// gft_mul64_tb -- iverilog KAT for the proposed GF-T64 multiplier (64-bit mantissa, 256-bit
// product path). Golden values from the exact BigUint recurrence (goldenfloat_ternary_ladder):
//   (9841, 0)^2       = (9841, 0)        1 * 1   = 1
//   (9841, 2^63)^2    = (9842, 2^61)      1.5^2   = 2.25  (mant_out = 2^(64-3), carry 1)
//   (9841, 2^62)^2    = (9841, 9*2^60)    1.25^2  = 1.5625 (mant_out = 9*M/16, carry 0)
module gft_mul64_tb;
    reg  [31:0] a_off, b_off;
    reg  [63:0] a_mant, b_mant;
    wire [31:0] out_off;
    wire [63:0] out_mant;
    integer errors = 0;

    gft_mul64 dut (.a_off(a_off), .a_mant(a_mant), .b_off(b_off), .b_mant(b_mant),
                   .out_off(out_off), .out_mant(out_mant));

    task chk;
        input [31:0] oa; input [63:0] ma; input [31:0] ob; input [63:0] mb;
        input [31:0] eo; input [63:0] em; input [127:0] name;
        begin
            a_off=oa; a_mant=ma; b_off=ob; b_mant=mb;
            #1;
            if (out_off !== eo || out_mant !== em) begin
                $display("FAIL %0s: (%0d,%h) want (%0d,%h)", name, out_off, out_mant, eo, em);
                errors = errors + 1;
            end else $display("ok:   %0s -> (%0d, 0x%h)", name, out_off, out_mant);
        end
    endtask

    initial begin
        chk(32'd9841, 64'd0,               32'd9841, 64'd0,               32'd9841, 64'd0,               "1*1=1");
        chk(32'd9841, 64'h8000000000000000, 32'd9841, 64'h8000000000000000, 32'd9842, 64'h2000000000000000, "1.5^2=2.25"); // 2^63 -> 2^61
        chk(32'd9841, 64'h4000000000000000, 32'd9841, 64'h4000000000000000, 32'd9841, 64'h9000000000000000, "1.25^2=1.5625"); // 2^62 -> 9*2^60
        if (errors == 0) $display("gft_mul64 KAT PASS");
        else $display("gft_mul64 KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
