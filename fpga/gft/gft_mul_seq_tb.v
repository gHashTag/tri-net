`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul_seq_tb -- iverilog KAT for the UART-datapath core (pack/unpack + gft_mul
// + handshake). Same golden vectors as the gft_mul iverilog KAT and the over-wire
// verifier: GF-T16 (41,0)^2 -> (42,0), (41,256)^2 -> (43,64), plus a non-square
// (44,0)*(45,0) -> (49,0). Packed 16-bit: (off<<9)|mant.
//   (41,0)   = 0x5200   -> (42,0)   = 0x5400
//   (41,256) = 0x5300   -> (43,64)  = 0x5640
//   (44,0)   = 0x5800, (45,0) = 0x5A00 -> (49,0) = 0x6200
// ============================================================================
module gft_mul_seq_tb;
    reg         clk = 0, rst = 1;
    reg         in_valid = 0;
    reg  [15:0] in_a = 0, in_b = 0;
    wire        in_ready, out_valid;
    wire [15:0] out_y;
    integer     errors = 0;

    always #5 clk = ~clk;

    gft_mul_seq dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_a(in_a), .in_b(in_b), .in_ready(in_ready),
        .out_valid(out_valid), .out_y(out_y), .out_ready(1'b1)
    );

    task check;
        input [15:0] a, b, expect_y;
        begin
            @(posedge clk);
            in_a <= a; in_b <= b; in_valid <= 1'b1;
            @(posedge clk);
            in_valid <= 1'b0;
            // wait for the result strobe
            wait (out_valid == 1'b1);
            @(posedge clk);   // sample after the registered update settles
            if (out_y !== expect_y) begin
                $display("FAIL: %h * %h -> %h (expected %h)", a, b, out_y, expect_y);
                errors = errors + 1;
            end else begin
                $display("ok:   %h * %h -> %h", a, b, out_y);
            end
            wait (out_valid == 1'b0);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        check(16'h5200, 16'h5200, 16'h5400); // (41,0)^2   = (42,0)
        check(16'h5300, 16'h5300, 16'h5640); // (41,256)^2 = (43,64)
        check(16'h5800, 16'h5A00, 16'h6200); // (44,0)*(45,0) = (49,0)

        if (errors == 0) $display("gft_mul_seq KAT PASS");
        else $display("gft_mul_seq KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
