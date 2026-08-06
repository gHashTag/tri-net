`timescale 1ns / 1ps
`default_nettype none
// gft_mul32_stream_tb -- byte-level KAT for the GF-T32 stream core. Frames a
// (a_off,a_mant)*(b_off,b_mant) multiply and checks the emitted 35-bit result.
// Golden (independent oracle, matches gft_mul32_tb):
//   (364,0)^2       = (364,0)          1*1     = 1
//   (364,2^24)^2    = (365,2^22)        1.5^2   = 2.25
module gft_mul32_stream_tb;
    reg        clk = 0, rst = 1;
    reg        rx_new = 0;
    reg  [7:0] rx_byte = 0;
    wire       out_valid;
    wire [15:0] out_off;
    wire [31:0] out_mant;
    integer    errors = 0;
    reg [15:0] cap_off; reg [31:0] cap_mant; reg saw;

    always #5 clk = ~clk;

    gft_mul32_stream dut (.clk(clk), .rst(rst), .rx_new(rx_new), .rx_byte(rx_byte),
                          .out_valid(out_valid), .out_off(out_off), .out_mant(out_mant));

    always @(posedge clk) if (out_valid) begin cap_off<=out_off; cap_mant<=out_mant; saw<=1; end

    task sb; input [7:0] b; begin @(posedge clk); rx_byte<=b; rx_new<=1; @(posedge clk); rx_new<=0; end endtask

    // one operand = off(2 LE) + mant(4 LE)
    task send_mul;
        input [15:0] aoff; input [31:0] amant; input [15:0] boff; input [31:0] bmant;
        begin
            sb(8'hAA); sb(8'h55);
            sb(aoff[7:0]); sb(aoff[15:8]);
            sb(amant[7:0]); sb(amant[15:8]); sb(amant[23:16]); sb(amant[31:24]);
            sb(boff[7:0]); sb(boff[15:8]);
            sb(bmant[7:0]); sb(bmant[15:8]); sb(bmant[23:16]); sb(bmant[31:24]);
            sb(8'h01); // cmd
            repeat (3) @(posedge clk);
        end
    endtask

    task chk; input [15:0] eo; input [31:0] em; input [255:0] name;
        begin
            if (!saw) begin $display("FAIL %0s: no emit", name); errors=errors+1; end
            else if (cap_off!==eo || cap_mant!==em) begin
                $display("FAIL %0s: got (%0d,%0d) want (%0d,%0d)", name, cap_off, cap_mant, eo, em); errors=errors+1;
            end else $display("ok:   %0s -> (%0d,%0d)", name, cap_off, cap_mant);
            saw <= 0;
        end
    endtask

    initial begin
        saw = 0;
        repeat (3) @(posedge clk); rst <= 0; @(posedge clk);
        send_mul(16'd364, 32'd0, 16'd364, 32'd0);
        chk(16'd364, 32'd0, "(364,0)^2 = 1");
        send_mul(16'd364, 32'd16777216, 16'd364, 32'd16777216);
        chk(16'd365, 32'd4194304, "(364,2^24)^2 = 2.25");
        if (errors == 0) $display("gft_mul32_stream KAT PASS");
        else $display("gft_mul32_stream KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
