`timescale 1ns / 1ps
`default_nettype none
// gft_dot4_stream_tb -- byte-level KAT for the 4-lane tile protocol core.
// Golden (independent oracle: four gft16 products reduced by the gft_add tree):
//   all four (41,0)^2                       = 4+4+4+4 = 16   -> 0x5800
//   (41,256)^2, (41,0)^2, (42,0)*(41,0), (41,0)^2 = 9+4+8+4 = 25 -> 0x5920
module gft_dot4_stream_tb;
    reg        clk = 0, rst = 1;
    reg        rx_new = 0;
    reg  [7:0] rx_byte = 0;
    wire       out_valid;
    wire [15:0] out_y;
    integer    errors = 0;
    reg [15:0] cap; reg saw;

    always #5 clk = ~clk;

    gft_dot4_stream dut (.clk(clk), .rst(rst), .rx_new(rx_new), .rx_byte(rx_byte),
                         .out_valid(out_valid), .out_y(out_y));

    always @(posedge clk) if (out_valid) begin cap<=out_y; saw<=1; end

    task sb; input [7:0] b; begin @(posedge clk); rx_byte<=b; rx_new<=1; @(posedge clk); rx_new<=0; end endtask
    task v16; input [15:0] x; begin sb(x[7:0]); sb(x[15:8]); end endtask

    task tile; input [15:0] a0,b0,a1,b1,a2,b2,a3,b3;
        begin
            sb(8'hAA); sb(8'h55);
            v16(a0); v16(b0); v16(a1); v16(b1); v16(a2); v16(b2); v16(a3); v16(b3);
            sb(8'h01); // cmd
            repeat (3) @(posedge clk);
        end
    endtask

    task want; input [15:0] w; input [127:0] name;
        begin
            if (!saw) begin $display("FAIL %0s: no emit", name); errors=errors+1; end
            else if (cap!==w) begin $display("FAIL %0s: got %h want %h", name, cap, w); errors=errors+1; end
            else $display("ok:   %0s -> %h", name, cap);
            saw <= 0;
        end
    endtask

    initial begin
        saw = 0;
        repeat (3) @(posedge clk); rst <= 0; @(posedge clk);
        tile(16'h5200,16'h5200, 16'h5200,16'h5200, 16'h5200,16'h5200, 16'h5200,16'h5200);
        want(16'h5800, "4x(41,0)^2=16");
        tile(16'h5300,16'h5300, 16'h5200,16'h5200, 16'h5400,16'h5200, 16'h5200,16'h5200);
        want(16'h5920, "9+4+8+4=25");
        if (errors == 0) $display("gft_dot4_stream KAT PASS");
        else $display("gft_dot4_stream KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
