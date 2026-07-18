`timescale 1ns/1ps
`default_nettype none
module fb61499_tb;
    localparam NO=4, W=8;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, req=0; reg [NO-1:0] valid=4'hF; reg [NO*W-1:0] xin; reg [NO*2-1:0] wgt;
    wire cnf; wire signed [W+3:0] y;
    fb61499 #(.NO(NO),.W(W)) dut(.clk(clk),.rst(rst),.req(req),.valid(valid),
        .xin(xin),.wgt(wgt),.cnf(cnf),.y(y));
    reg fired; always @(posedge clk) if(cnf) fired<=1;
    // stimulus on NEGEDGE so signals are stable at the DUT's posedge (no race)
    initial begin
        xin = {8'sd3, 8'sd7, -8'sd4, 8'sd10};   // x=[10,-4,7,3]
        wgt = {2'b00, 2'b10, 2'b01, 2'b01};     // w=[+1,+1,-1,0] -> 10-4-7+0 = -1
        @(negedge clk); rst=0;
        fired=0; valid=4'b1011; @(negedge clk) req=1; @(negedge clk) req=0; @(negedge clk);@(negedge clk);
        $display("[1] no-data on op2 + req : fired=%0d (expect 0 -- firing gate holds)", fired);
        fired=0; valid=4'b1111; @(negedge clk) req=1; @(negedge clk) req=0; @(negedge clk);@(negedge clk);
        $display("[2] all present + req    : fired=%0d  y=%0d (expect fired=1, y=-1)", fired, y);
        fired=0; req=0; repeat(4) @(negedge clk);
        $display("[3] all present, no req  : fired=%0d (expect 0 -- no event)", fired);
        $finish;
    end
endmodule
`default_nettype wire
