`timescale 1ns / 1ps
`default_nettype none
// GF-T8 KAT: 0xD0=(13,0)=1.0, 0xD8=(13,8)=1.5, 0xE0=(14,0)=2.0
//   1*1=1     -> (13,0)=0xD0 ; 1.5^2=2.25 -> (14,2)=0xE2 ; 1*2=2 -> (14,0)=0xE0
module gft_mul8_seq_tb;
    reg clk=0, rst=1, in_valid=0; reg [15:0] in_a=0,in_b=0;
    wire in_ready,out_valid; wire [15:0] out_y; integer errors=0;
    always #5 clk=~clk;
    gft_mul8_seq dut(.clk(clk),.rst(rst),.in_valid(in_valid),.in_a(in_a),.in_b(in_b),
                     .in_ready(in_ready),.out_valid(out_valid),.out_y(out_y),.out_ready(1'b1));
    task chk; input [15:0] a,b,ey; begin
        @(posedge clk); in_a<=a; in_b<=b; in_valid<=1;
        @(posedge clk); in_valid<=0; wait(out_valid==1); @(posedge clk);
        if(out_y!==ey) begin $display("FAIL %h*%h -> %h want %h",a,b,out_y,ey); errors=errors+1; end
        else $display("ok: %h*%h -> %h",a,b,out_y); wait(out_valid==0); end
    endtask
    initial begin repeat(4)@(posedge clk); rst<=0; repeat(2)@(posedge clk);
        chk(16'h00D0,16'h00D0,16'h00D0); // 1*1=1
        chk(16'h00D8,16'h00D8,16'h00E2); // 1.5^2=2.25
        chk(16'h00D0,16'h00E0,16'h00E0); // 1*2=2
        if(errors==0) $display("gft_mul8_seq KAT PASS"); else $display("gft_mul8_seq KAT FAIL: %0d",errors);
        $finish; end
endmodule
`default_nettype wire
