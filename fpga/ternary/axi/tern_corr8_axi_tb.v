`timescale 1ns/1ps
// Drive the ternary despreader entirely through its AXI4-Lite port, as the Zynq
// PS would: write the reference code to reg_ctrl, stream a matched burst on the
// data plane, then read the correlation peak back from reg_status.
module tern_corr8_axi_tb;
    localparam integer W=16, ACC=20, A=100;
    localparam [1:0] P=2'b01, M=2'b10, Z=2'b00;

    reg clk=0, rst_n=0;
    reg [7:0] awaddr=0, araddr=0; reg awvalid=0, wvalid=0, bready=0, arvalid=0, rready=0;
    reg [31:0] wdata=0; wire awready, wready, bvalid, arready, rvalid; wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    reg s_valid=0; reg signed [W-1:0] s_data=0;

    tern_corr8_axi #(.W(W),.ACC(ACC)) dut(.clk(clk),.rst_n(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(4'hF),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .s_valid(s_valid),.s_data(s_data));
    always #5 clk=~clk;

    task axi_write(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk); awaddr=a; wdata=d; awvalid=1; wvalid=1; bready=1;
            wait(bvalid); @(negedge clk); awvalid=0; wvalid=0; bready=0;
            @(negedge clk);
        end
    endtask
    task axi_read(input [7:0] a, output [31:0] d);
        begin
            @(negedge clk); araddr=a; arvalid=1; rready=1;
            wait(rvalid); d=rdata; @(negedge clk); arvalid=0; rready=0;
            @(negedge clk);
        end
    endtask

    reg [1:0] code [0:7]; reg [15:0] tap_word; reg [31:0] rd; integer k;
    function integer decA(input [1:0] w); decA=(w==P)?A:(w==M)?-A:0; endfunction
    initial begin
        code[0]=P;code[1]=P;code[2]=Z;code[3]=M;code[4]=M;code[5]=M;code[6]=Z;code[7]=P;
        tap_word=0; for(k=0;k<8;k=k+1) tap_word[k*2 +: 2]=code[k];

        repeat(3) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);

        // PS writes the reference code + load pulse (bit16) to reg_ctrl @ 0x00
        axi_write(8'h00, {15'd0, 1'b1, tap_word});
        repeat(12) @(negedge clk);              // let the loader walk 8 taps in

        // data plane: stream the matched burst (window aligns -> peak 6 taps * A)
        for(k=0;k<8;k=k+1) begin @(negedge clk); s_valid=1; s_data=decA(code[7-k]); end
        @(negedge clk); s_valid=0; repeat(4) @(negedge clk);

        // PS reads the correlation peak from reg_status @ 0x04
        axi_read(8'h04, rd);
        $display("AXI read reg_status (peak) = %0d  (want %0d)", $signed(rd), 6*A);
        if ($signed(rd) == 6*A) $display("AXI-LITE DESPREADER: PS wrote code, streamed samples, read peak -- bridge works");
        else                    $display("AXI-LITE DESPREADER: FAILED (got %0d)", $signed(rd));
        $finish;
    end
endmodule
