`timescale 1ns / 1ps
`default_nettype none
// gft_macc_tb -- iverilog KAT for the streaming MAC. Golden accumulator values are an
// independent oracle (integer gft_mul + gft_add, value-domain cross-checked).
//
// Seq A: four terms of (41,0)^2 = 4.0 each -> running sum 4, 8, 12, 16:
//   0x5400 (42,0)=4, 0x5600 (43,0)=8, 0x5700 (43,256)=12, 0x5800 (44,0)=16
// Seq B: (41,256)^2 = 9, then + (44,0)*(45,0) = 512 -> 9, 521:
//   0x5640 (43,64)=9, 0x6209 (49,9)=521
module gft_macc_tb;
    reg         clk = 0, rst = 1;
    reg         in_valid = 0, first = 0;
    reg  [15:0] a = 0, b = 0;
    wire [15:0] acc;
    integer     errors = 0;

    always #5 clk = ~clk;

    gft_macc dut (.clk(clk), .rst(rst), .in_valid(in_valid), .first(first), .a(a), .b(b), .acc(acc));

    task fold;  // apply one (a,b) term, then check the accumulator
        input        is_first;
        input [15:0] ia, ib, expect_acc;
        begin
            @(posedge clk);
            a <= ia; b <= ib; first <= is_first; in_valid <= 1'b1;
            @(posedge clk);
            in_valid <= 1'b0; first <= 1'b0;
            #1;
            if (acc !== expect_acc) begin
                $display("FAIL: fold %h*%h (first=%b) -> acc %h (expected %h)", ia, ib, is_first, acc, expect_acc);
                errors = errors + 1;
            end else $display("ok:   fold %h*%h -> acc %h", ia, ib, acc);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // Seq A: 4x (41,0)^2
        fold(1'b1, 16'h5200, 16'h5200, 16'h5400); // 4
        fold(1'b0, 16'h5200, 16'h5200, 16'h5600); // 8
        fold(1'b0, 16'h5200, 16'h5200, 16'h5700); // 12
        fold(1'b0, 16'h5200, 16'h5200, 16'h5800); // 16

        // Seq B: 9 then +512
        fold(1'b1, 16'h5300, 16'h5300, 16'h5640); // 9
        fold(1'b0, 16'h5800, 16'h5A00, 16'h6209); // 9 + 512 = 521

        if (errors == 0) $display("gft_macc KAT PASS");
        else $display("gft_macc KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
