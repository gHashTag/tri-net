`timescale 1ns/1ps
`default_nettype none
module yapf_cascade_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, req_a=0, req_b=0; reg [1:0] va=2'b11, vb=2'b11;
    reg [15:0] xa, xb; reg [3:0] wa, wb, wc;
    wire cnf_c; wire signed [15:0] yc;
    yapf_cascade dut(.clk(clk),.rst(rst),.req_a(req_a),.req_b(req_b),.va(va),.vb(vb),
        .xa(xa),.xb(xb),.wa(wa),.wb(wb),.wc(wc),.cnf_c(cnf_c),.yc(yc));
    reg fired; always @(posedge clk) if(cnf_c) fired<=1;
    initial begin
        // tier-1a: [10,-4] w=[+1,+1] -> ya = 6
        // tier-1b: [7, 3] w=[+1,-1] -> yb = 4
        // tier-2 : [ya,yb]=[6,4] w=[+1,+1] -> yc = 10
        xa={ -8'sd4, 8'sd10 }; wa=4'b01_01;   // +ya components
        xb={  8'sd3, 8'sd7  }; wb=4'b10_01;   // 7 - 3
        wc=4'b01_01;                          // ya + yb
        @(negedge clk) rst=0;
        fired=0;
        // fire tier-1a only first -> tier-2 must NOT fire (only one operand present)
        @(negedge clk) req_a=1; @(negedge clk) req_a=0; repeat(3) @(negedge clk);
        $display("[1] only tier-1a fired: cnf_c=%0d (expect 0 -- wave not complete)", fired);
        // now fire tier-1b -> the wave completes, tier-2 fires
        @(negedge clk) req_b=1; @(negedge clk) req_b=0; repeat(4) @(negedge clk);
        $display("[2] both tiers fired: cnf_c seen=%0d  yc=%0d (expect fired=1, yc=10)", fired, yc);
        $finish;
    end
endmodule
`default_nettype wire
