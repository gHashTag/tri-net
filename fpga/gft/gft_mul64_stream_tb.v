`timescale 1ns / 1ps
// Byte-level KAT for gft_mul64_stream: feed a full frame and check the folded GF-T64
// result. GF-T64: mant_one 2^64, bias 9841. 1.5 = (9841, 2^63); 1.5*1.5 = 2.25 =
// (9842, 2^61) (same identity as gft_mul64's KAT). Also 1.0 = (9841, 0); 1.0*1.0 = (9841,0).
module gft_mul64_stream_tb;
    reg clk = 0, rst = 1, rx_new = 0;
    reg [7:0] rx_byte = 0;
    wire dv;
    wire [15:0] oo;
    wire [63:0] om;
    integer fails = 0;
    gft_mul64_stream dut (.clk(clk), .rst(rst), .rx_new(rx_new), .rx_byte(rx_byte),
                          .out_valid(dv), .out_off(oo), .out_mant(om));
    always #5 clk = ~clk;

    task send(input [7:0] b);
        begin
            @(negedge clk); rx_byte = b; rx_new = 1;
            @(negedge clk); rx_new = 0;
        end
    endtask

    // send a 79-bit operand: offset (16b -> 2 LE bytes) + mantissa (64b -> 8 LE bytes)
    task send_off(input [15:0] o); begin send(o[7:0]); send(o[15:8]); end endtask
    task send_m64(input [63:0] m); begin
        send(m[7:0]); send(m[15:8]); send(m[23:16]); send(m[31:24]);
        send(m[39:32]); send(m[47:40]); send(m[55:48]); send(m[63:56]);
    end endtask

    task frame(input [15:0] ao, input [63:0] am, input [15:0] bo, input [63:0] bm);
        begin
            send(8'hAA); send(8'h55);
            send_off(ao); send_m64(am);
            send_off(bo); send_m64(bm);
            send(8'h00); // cmd -> fold
        end
    endtask

    task chk(input [95:0] n, input [15:0] eo, input [63:0] em);
        begin
            // wait for the valid pulse
            @(posedge dv);
            @(negedge clk);
            if (oo !== eo || om !== em) begin $display("FAIL %0s: (%0d, %h) exp (%0d, %h)", n, oo, om, eo, em); fails=fails+1; end
            else $display("ok   %0s: (%0d, 0x%h)", n, oo, om);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0; repeat (2) @(negedge clk);
        fork
            frame(16'd9841, 64'h8000000000000000, 16'd9841, 64'h8000000000000000); // 1.5 * 1.5
            chk("stream 1.5^2 -> 2.25", 16'd9842, 64'h2000000000000000);            // (9842, 2^61)
        join
        fork
            frame(16'd9841, 64'd0, 16'd9841, 64'd0); // 1.0 * 1.0
            chk("stream 1.0^2 -> 1.0", 16'd9841, 64'd0);
        join
        if (fails==0) $display("KAT PASS: gft_mul64_stream framing + fold = gft_mul64 result");
        else $display("KAT FAIL: %0d", fails);
        $finish;
    end
endmodule
