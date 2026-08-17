`timescale 1ns/1ps
// ps7_ad9361_real is the design with real package pins: fourteen inputs, the
// vendor's own IBUF and IDDR, and nothing driving any output. It has been built
// and loaded on silicon but never checked functionally, because a pinless
// harness cannot instantiate the IOB capture stage and so cannot exercise it.
//
// Here the stimulus arrives on the ports, as it would from the radio.
module tb;
  localparam N=63, ACC=24;
  reg clk50 = 0; always #10 clk50 = ~clk50;

  // bus stimulus, driven onto the real ports
  reg bclk = 0; integer bper = 10;
  always #(bper) bclk = ~bclk;
  reg rxclk = 0;   always @(posedge bclk) rxclk <= ~rxclk;
  reg rxframe = 0; always @(posedge bclk) if (rxclk) rxframe <= ~rxframe;
  reg [5:0] pn_idx = 0; reg [1:0] div4 = 0;
  wire [5:0] pn_rev = 6'd62 - pn_idx;
  wire pn_bit = pn_rev[0] ^ pn_rev[2] ^ pn_rev[4];
  wire [11:0] pn_chip = pn_bit ? 12'h7FF : 12'h801;
  always @(posedge bclk) begin
    div4 <= div4 + 1'b1;
    if (div4 == 2'd3) pn_idx <= (pn_idx == 6'd62) ? 6'd0 : pn_idx + 1'b1;
  end

  ps7_ad9361_real dut (.rx_clk_in(rxclk), .rx_frame_in(rxframe),
                       .rx_data_in(pn_chip));

  initial begin
    dut.ps7_i.frstn = 4'b0000; dut.ps7_i.gpo = 64'd0;
    #200 dut.ps7_i.frstn = 4'b1111;
  end
  always @(clk50) dut.ps7_i.fclk[0] = clk50;

  task axi_write(input [31:0] a, input [31:0] d);
    integer g; begin
      @(posedge clk50);
      dut.ps7_i.awaddr <= a; dut.ps7_i.awlen <= 0; dut.ps7_i.awvalid <= 1;
      g=0; while (!dut.gp_awready && g<400) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.awvalid <= 0;
      dut.ps7_i.wdata <= d; dut.ps7_i.wlast <= 1; dut.ps7_i.wvalid <= 1;
      g=0; while (!dut.gp_wready && g<400) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.wvalid <= 0; dut.ps7_i.bready <= 1;
      g=0; while (!dut.gp_bvalid && g<2000) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.bready <= 0;
    end
  endtask
  reg [31:0] rdval;
  task axi_read(input [31:0] a);
    integer g; begin
      @(posedge clk50);
      dut.ps7_i.araddr <= a; dut.ps7_i.arlen <= 0; dut.ps7_i.arvalid <= 1;
      g=0; while (!dut.gp_arready && g<400) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.arvalid <= 0; dut.ps7_i.rready <= 1;
      g=0; while (!dut.gp_rvalid && g<2000) begin @(posedge clk50); g=g+1; end
      rdval = dut.gp_rdata;
      @(posedge clk50); dut.ps7_i.rready <= 0;
    end
  endtask

  integer tp [0:N-1];
  integer i,k,errs,expect_,nz,distinct_hi,distinct_lo;
  reg [15:0] ins [0:127]; reg [31:0] outs [0:127];
  reg [31:0] stat;

  initial begin
    for (i=0;i<N;i=i+1) tp[i] = ((i&1)^((i>>2)&1)^((i>>4)&1)) ? 1 : -1;
    #400;
    axi_read(32'h4001_0000); $display("bridge magic : %h", rdval);
    axi_read(32'h4000_0000); $display("ADI version  : %h", rdval);
    axi_write(32'h4000_0040, 32'h3);
    axi_write(32'h4000_0400, 32'h51);
    #20000;
    axi_read(32'h4001_0014); $display("l_clk heartbeat A : %0d", rdval);
    #20000;
    axi_read(32'h4001_0014); $display("l_clk heartbeat B : %0d  (must differ)", rdval);
    axi_read(32'h4001_000C);
    $display("state word   : %h  saw_valid %0d  enable %0d  any_nonzero %0d",
             rdval, rdval[0], rdval[1], rdval[3]);
    axi_read(32'h4001_0010); $display("last sample  : %h", rdval);
    axi_write(32'h4001_0020, 32'h0); #2000;
    axi_write(32'h4001_0020, 32'h1); #600000;
    axi_read(32'h4001_0024); stat = rdval;
    $display("capture status: %h", stat);
    nz = 0;
    for (k=0;k<128;k=k+1) begin
      axi_read(32'h4001_0400 + k*4); ins[k] = rdval[15:0];
      axi_read(32'h4001_0800 + k*4); outs[k] = rdval;
      if (ins[k] != 0) nz = nz + 1;
    end
    $display("non-zero input samples: %0d of 128", nz);
    distinct_hi = 0; distinct_lo = 0;
    for (k=0;k<128;k=k+1) begin
      if (ins[k] == 16'h07FF) distinct_hi = distinct_hi + 1;
      if (ins[k] == 16'hF801) distinct_lo = distinct_lo + 1;
    end
    $display("samples equal to +2047: %0d   to -2047: %0d   other: %0d",
             distinct_hi, distinct_lo, 128 - distinct_hi - distinct_lo);
    errs = 0;
    for (k=N+2;k<128;k=k+1) begin
      expect_ = 0;
      for (i=0;i<N;i=i+1)
        expect_ = expect_ + tp[i]*$signed(ins[k-(outs[k][24] ? 2 : 1)-i]);
      if ($signed(outs[k][23:0]) !== $signed(expect_[ACC-1:0])) errs = errs + 1;
    end
    $display("per-sample lag: %0d mismatches of %0d", errs, 128-(N+2));
    $display("first eight in : %h %h %h %h %h %h %h %h",
             ins[0],ins[1],ins[2],ins[3],ins[4],ins[5],ins[6],ins[7]);
    $finish;
  end
  initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
