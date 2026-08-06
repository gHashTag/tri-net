`timescale 1ns / 1ps
`default_nettype none
// gft_macc_stream_tb -- byte-level KAT for the streaming-MAC protocol core.
// Streams per-term frames [AA 55 a_lo a_hi b_lo b_hi ctrl] and checks the emitted
// accumulator on the LAST term. Golden values from the independent gft_macc oracle.
module gft_macc_stream_tb;
    reg        clk = 0, rst = 1;
    reg        rx_new = 0;
    reg  [7:0] rx_byte = 0;
    wire       out_valid;
    wire [15:0] out_y;
    integer    errors = 0;
    reg [15:0] captured;
    reg        saw;

    always #5 clk = ~clk;

    gft_macc_stream dut (.clk(clk), .rst(rst), .rx_new(rx_new), .rx_byte(rx_byte),
                         .out_valid(out_valid), .out_y(out_y));

    // capture any emit
    always @(posedge clk) if (out_valid) begin captured <= out_y; saw <= 1'b1; end

    task send_byte; input [7:0] b;
        begin @(posedge clk); rx_byte <= b; rx_new <= 1'b1; @(posedge clk); rx_new <= 1'b0; end
    endtask

    task send_term; input [15:0] a, b; input [7:0] ctrl;
        begin
            send_byte(8'hAA); send_byte(8'h55);
            send_byte(a[7:0]); send_byte(a[15:8]);
            send_byte(b[7:0]); send_byte(b[15:8]);
            send_byte(ctrl);
            repeat (3) @(posedge clk); // let fold + emit settle
        end
    endtask

    task expect_dot; input [15:0] want; input [127:0] name;
        begin
            if (!saw) begin $display("FAIL %0s: no emit", name); errors=errors+1; end
            else if (captured !== want) begin $display("FAIL %0s: got %h want %h", name, captured, want); errors=errors+1; end
            else $display("ok:   %0s -> %h", name, captured);
            saw <= 1'b0;
        end
    endtask

    initial begin
        saw = 0; captured = 0;
        repeat (3) @(posedge clk); rst <= 1'b0; @(posedge clk);

        // length-4 dot: 4x (41,0)^2 = 16
        send_term(16'h5200, 16'h5200, 8'h01); // first
        send_term(16'h5200, 16'h5200, 8'h00);
        send_term(16'h5200, 16'h5200, 8'h00);
        send_term(16'h5200, 16'h5200, 8'h02); // last
        expect_dot(16'h5800, "4x(41,0)^2=16");

        // length-2 dot: 9 + 512 = 521
        send_term(16'h5300, 16'h5300, 8'h01); // first
        send_term(16'h5800, 16'h5A00, 8'h02); // last
        expect_dot(16'h6209, "9+512=521");

        // length-1 dot: (50,0)^2 = 2^20  (first & last)
        send_term(16'h6400, 16'h6400, 8'h03);
        expect_dot(16'h7800, "(50,0)^2");

        if (errors == 0) $display("gft_macc_stream KAT PASS");
        else $display("gft_macc_stream KAT FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
`default_nettype wire
