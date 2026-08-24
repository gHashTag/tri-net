`timescale 1ns / 1ps
`default_nettype none
// gft_dot2_seq_tb -- iverilog KAT for the MAC datapath core through its handshake.
// Same golden vectors as gft_dot2_tb: a1*b1 + a2*b2, packed (off<<9)|mant.
module gft_dot2_seq_tb;
    reg         clk = 0, rst = 1;
    reg         in_valid = 0;
    reg  [15:0] a1 = 0, b1 = 0, a2 = 0, b2 = 0;
    wire        in_ready, out_valid;
    wire [15:0] out_y;
    integer     errors = 0;

    always #5 clk = ~clk;

    gft_dot2_seq dut (
        .clk(clk), .rst(rst), .in_valid(in_valid),
        .a1(a1), .b1(b1), .a2(a2), .b2(b2),
        .in_ready(in_ready), .out_valid(out_valid), .out_y(out_y), .out_ready(1'b1)
    );

    task check;
        input [15:0] ia1, ib1, ia2, ib2, expect_y;
        begin
            @(posedge clk);
            a1 <= ia1; b1 <= ib1; a2 <= ia2; b2 <= ib2; in_valid <= 1'b1;
            @(posedge clk);
            in_valid <= 1'b0;
            wait (out_valid == 1'b1);
            @(posedge clk);
            if (out_y !== expect_y) begin
                $display("FAIL: %h*%h + %h*%h -> %h (expected %h)", ia1, ib1, ia2, ib2, out_y, expect_y);
                errors = errors + 1;
            end else $display("ok:   %h*%h + %h*%h -> %h", ia1, ib1, ia2, ib2, out_y);
            wait (out_valid == 1'b0);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);
        check(16'h5300, 16'h5300, 16'h5200, 16'h5200, 16'h5740); // 9+4=13
        check(16'h5200, 16'h5200, 16'h5400, 16'h5200, 16'h5700); // 4+8=12
        check(16'h5800, 16'h5A00, 16'h6400, 16'h6400, 16'h7800); // 512+2^20
        if (errors == 0) $display("gft_dot2_seq KAT PASS");
        else $display("gft_dot2_seq KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
