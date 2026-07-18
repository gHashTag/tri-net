`timescale 1ns/1ps
`default_nettype none
module yapf_fabric_tb;
    localparam NB=4, W=8;
    reg clk=0; always #5 clk=~clk;
    reg rst=1; reg [4*W-1:0] ext; reg [NB*10-1:0] cfg;
    wire signed [W-1:0] yout;
    yapf_fabric #(.NB(NB),.W(W)) dut(.clk(clk),.rst(rst),.ext(ext),.cfg(cfg),.yout(yout));
    // cfg per block = {w[3:0], sel1[2:0], sel0[2:0]}. Sources: 0..3=ext, 4..7=y0..y3.
    // ext = [5, 3, 8, 2]
    task run; begin rst=1; @(negedge clk); @(negedge clk); rst=0; repeat(8) @(negedge clk); end endtask
    initial begin
        ext = {8'sd2, 8'sd8, 8'sd3, 8'sd5};   // ext0=5,ext1=3,ext2=8,ext3=2
        // TOPOLOGY 1 (a tree):  y0=ext0+ext1=8, y1=ext2+ext3=10, y3=y0+y1=18
        //   b0: w=+1,+1 sel1=1(ext1) sel0=0(ext0)
        //   b1: w=+1,+1 sel1=3(ext3) sel0=2(ext2)
        //   b3: w=+1,+1 sel1=5(y1)   sel0=4(y0)
        cfg = { {4'b0101,3'd5,3'd4},    // b3 = y0 + y1
                { 10'd0 },              // b2 unused
                {4'b0101,3'd3,3'd2},    // b1 = ext2 + ext3
                {4'b0101,3'd1,3'd0} };  // b0 = ext0 + ext1
        run; $display("[topology 1: y3=(ext0+ext1)+(ext2+ext3)] yout=%0d (expect 18)", yout);
        // TOPOLOGY 2 (reconfigure, same bitstream): y3 = ext2 - y0 = 8 - 8 = 0
        cfg = { {4'b1001,3'd4,3'd2},    // b3 = +ext2 - y0
                { 10'd0 },
                {4'b0101,3'd3,3'd2},
                {4'b0101,3'd1,3'd0} };
        run; $display("[topology 2: y3=ext2 - (ext0+ext1)]   yout=%0d (expect 0)", yout);
        // TOPOLOGY 3: deeper -- y3 = y1 - y0 = 10 - 8 = 2
        cfg = { {4'b1001,3'd4,3'd5},    // b3 = +y1 - y0
                { 10'd0 },
                {4'b0101,3'd3,3'd2},
                {4'b0101,3'd1,3'd0} };
        run; $display("[topology 3: y3=(ext2+ext3)-(ext0+ext1)] yout=%0d (expect 2)", yout);
        $finish;
    end
endmodule
`default_nettype wire
