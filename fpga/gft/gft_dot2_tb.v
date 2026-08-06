`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot2_tb -- iverilog KAT for the GF-T16 MAC kernel. Golden values are an
// INDEPENDENT oracle: each product from the integer gft_mul recompute, the sum from
// the integer gft_add recompute, cross-checked in the value domain.
//   a1*b1 + a2*b2, packed (off<<9)|mant:
//   (41,256)^2 + (41,0)^2   = (43,64)+(42,0) = (43,320)  9.0 + 4.0 = 13.0   0x5740
//   (41,0)^2   + (42,0)*(41,0)= (42,0)+(43,0) = (43,256)  4.0 + 8.0 = 12.0   0x5700
//   (44,0)*(45,0)+(50,0)^2   = (49,0)+(60,0) = (60,0)   512 + 1048576 (small
//                                                        term underflows) 0x7800
// ============================================================================
module gft_dot2_tb;
    reg  [15:0] a1, b1, a2, b2;
    wire [15:0] y;
    integer errors = 0;

    gft_dot2 dut (.a1(a1), .b1(b1), .a2(a2), .b2(b2), .y(y));

    task check;
        input [15:0] ia1, ib1, ia2, ib2, expect_y;
        begin
            a1 = ia1; b1 = ib1; a2 = ia2; b2 = ib2;
            #1;
            if (y !== expect_y) begin
                $display("FAIL: %h*%h + %h*%h -> %h (expected %h)", ia1, ib1, ia2, ib2, y, expect_y);
                errors = errors + 1;
            end else begin
                $display("ok:   %h*%h + %h*%h -> %h", ia1, ib1, ia2, ib2, y);
            end
        end
    endtask

    initial begin
        check(16'h5300, 16'h5300, 16'h5200, 16'h5200, 16'h5740); // 9 + 4  = 13
        check(16'h5200, 16'h5200, 16'h5400, 16'h5200, 16'h5700); // 4 + 8  = 12
        check(16'h5800, 16'h5A00, 16'h6400, 16'h6400, 16'h7800); // 512 + 2^20
        if (errors == 0) $display("gft_dot2 KAT PASS");
        else $display("gft_dot2 KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
