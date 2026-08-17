`timescale 1ns/1ps
// A Lite slave with programmable latency and a dead region, so the bridge is
// tested against both a slow slave and one that never answers.
module lite_slave(
  input clk, input rstn,
  input [31:0] awaddr, input awvalid, output reg awready,
  input [31:0] wdata, input [3:0] wstrb, input wvalid, output reg wready,
  output reg bvalid, output reg [1:0] bresp, input bready,
  input [31:0] araddr, input arvalid, output reg arready,
  output reg [31:0] rdata, output reg [1:0] rresp, output reg rvalid, input rready);
  reg [31:0] mem [0:63];
  reg [31:0] a; reg [3:0] dly;
  integer i; initial begin for (i=0;i<64;i=i+1) mem[i]=32'h0; mem[0]=32'h000A0300; end
  // 0xDEAD_xxxx is the dead region: no response ever
  wire dead_w = (awaddr[31:16] == 16'hDEAD);
  wire dead_r = (araddr[31:16] == 16'hDEAD);
  always @(posedge clk) if (!rstn) begin
    awready<=0; wready<=0; bvalid<=0; arready<=0; rvalid<=0; dly<=0;
  end else begin
    awready <= awvalid & ~dead_w & ~awready & ~bvalid;
    wready  <= wvalid  & ~dead_w & ~wready  & ~bvalid;
    if (awvalid & awready) a <= awaddr;
    if (wvalid & wready) begin mem[awaddr[7:2]] <= wdata; bvalid <= 1; bresp <= 0; end
    else if (bvalid & bready) bvalid <= 0;
    arready <= arvalid & ~dead_r & ~arready & ~rvalid;
    if (arvalid & arready) begin rdata <= mem[araddr[7:2]]; rresp <= 0; rvalid <= 1; end
    else if (rvalid & rready) rvalid <= 0;
  end
endmodule

module tb;
  reg clk=0, rstn=0; always #5 clk = ~clk;
  reg [11:0] awid=0, arid=0; reg [31:0] awaddr=0, araddr=0, wdata=0;
  reg [3:0] awlen=0, arlen=0, wstrb=4'hF;
  reg awvalid=0, wvalid=0, wlast=0, bready=0, arvalid=0, rready=0;
  wire awready, wready, bvalid, arready, rvalid, rlast;
  wire [1:0] bresp, rresp; wire [31:0] rdata; wire [11:0] bid, rid;
  wire [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
  wire [3:0] m_wstrb; wire [1:0] m_bresp, m_rresp;
  wire m_awvalid,m_awready,m_wvalid,m_wready,m_bvalid,m_bready;
  wire m_arvalid,m_arready,m_rvalid,m_rready;

  axi3_to_lite #(.TIMEOUT(64)) dut (.clk(clk),.rstn(rstn),
    .s_awid(awid),.s_awaddr(awaddr),.s_awlen(awlen),.s_awvalid(awvalid),.s_awready(awready),
    .s_wdata(wdata),.s_wstrb(wstrb),.s_wlast(wlast),.s_wvalid(wvalid),.s_wready(wready),
    .s_bid(bid),.s_bresp(bresp),.s_bvalid(bvalid),.s_bready(bready),
    .s_arid(arid),.s_araddr(araddr),.s_arlen(arlen),.s_arvalid(arvalid),.s_arready(arready),
    .s_rid(rid),.s_rdata(rdata),.s_rresp(rresp),.s_rlast(rlast),.s_rvalid(rvalid),.s_rready(rready),
    .m_awaddr(m_awaddr),.m_awvalid(m_awvalid),.m_awready(m_awready),
    .m_wdata(m_wdata),.m_wstrb(m_wstrb),.m_wvalid(m_wvalid),.m_wready(m_wready),
    .m_bvalid(m_bvalid),.m_bresp(m_bresp),.m_bready(m_bready),
    .m_araddr(m_araddr),.m_arvalid(m_arvalid),.m_arready(m_arready),
    .m_rdata(m_rdata),.m_rresp(m_rresp),.m_rvalid(m_rvalid),.m_rready(m_rready));

  lite_slave slv (.clk(clk),.rstn(rstn),
    .awaddr(m_awaddr),.awvalid(m_awvalid),.awready(m_awready),
    .wdata(m_wdata),.wstrb(m_wstrb),.wvalid(m_wvalid),.wready(m_wready),
    .bvalid(m_bvalid),.bresp(m_bresp),.bready(m_bready),
    .araddr(m_araddr),.arvalid(m_arvalid),.arready(m_arready),
    .rdata(m_rdata),.rresp(m_rresp),.rvalid(m_rvalid),.rready(m_rready));

  integer errors = 0; integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  task do_write(input [31:0] ad, input [31:0] dt, input [3:0] len, input [11:0] id);
    integer k; integer guard; begin
      @(posedge clk); awaddr<=ad; awlen<=len; awid<=id; awvalid<=1;
      guard=0; while (!awready && guard<500) begin @(posedge clk); guard=guard+1; end
      @(posedge clk); awvalid<=0;
      for (k=0;k<=len;k=k+1) begin
        wdata<=dt+k; wlast<=(k==len); wvalid<=1;
        guard=0; while (!wready && guard<500) begin @(posedge clk); guard=guard+1; end
        @(posedge clk);
      end
      wvalid<=0; bready<=1;
      guard=0; while (!bvalid && guard<2000) begin @(posedge clk); guard=guard+1; end
      if (!bvalid) begin $display("  FAIL: write to %h never responded (HANG)", ad); errors=errors+1; end
      else if (bid !== id) begin $display("  FAIL: bid %h != awid %h", bid, id); errors=errors+1; end
      @(posedge clk); bready<=0;
    end
  endtask

  task do_read(input [31:0] ad, input [3:0] len, input [11:0] id, input [31:0] expect0);
    integer k; integer guard; begin
      @(posedge clk); araddr<=ad; arlen<=len; arid<=id; arvalid<=1;
      guard=0; while (!arready && guard<500) begin @(posedge clk); guard=guard+1; end
      @(posedge clk); arvalid<=0; rready<=1;
      for (k=0;k<=len;k=k+1) begin
        guard=0; while (!rvalid && guard<2000) begin @(posedge clk); guard=guard+1; end
        if (!rvalid) begin $display("  FAIL: read %h beat %0d never came (HANG)", ad, k); errors=errors+1; k=len; end
        else begin
          if (k==0 && rdata !== expect0) begin
            $display("  FAIL: read %h = %h, expected %h", ad, rdata, expect0); errors=errors+1; end
          if (rid !== id) begin $display("  FAIL: rid %h != arid %h", rid, id); errors=errors+1; end
          if (rlast !== (k==len)) begin $display("  FAIL: rlast wrong on beat %0d", k); errors=errors+1; end
        end
        @(posedge clk);
      end
      rready<=0;
    end
  endtask

  initial begin
    repeat (4) @(posedge clk); rstn <= 1; repeat (4) @(posedge clk);

    $display("1. read the version register (single beat)");
    do_read(32'h0000_0000, 4'd0, 12'h123, 32'h000A0300);

    $display("2. write then read back (single beat)");
    do_write(32'h0000_0010, 32'hCAFE_0001, 4'd0, 12'h0A5);
    do_read (32'h0000_0010, 4'd0, 12'h0A5, 32'hCAFE_0001);

    $display("3. burst write of 4 beats, then read each back");
    do_write(32'h0000_0020, 32'h1000_0000, 4'd3, 12'h777);
    do_read (32'h0000_0020, 4'd0, 12'h1, 32'h1000_0000);
    do_read (32'h0000_0024, 4'd0, 12'h2, 32'h1000_0001);
    do_read (32'h0000_0028, 4'd0, 12'h3, 32'h1000_0002);
    do_read (32'h0000_002C, 4'd0, 12'h4, 32'h1000_0003);

    $display("4. burst read of 4 beats");
    do_read (32'h0000_0020, 4'd3, 12'h321, 32'h1000_0000);

    $display("5. THE IMPORTANT ONE: a slave that never answers must not hang the CPU");
    do_read (32'hDEAD_0000, 4'd0, 12'h0FF, 32'hBADA_C7E5);
    if (rresp !== 2'b10) begin $display("  FAIL: dead read gave resp %b, expected SLVERR", rresp); errors=errors+1; end
    do_write(32'hDEAD_0000, 32'h0, 4'd0, 12'h0EE);
    if (bresp !== 2'b10) begin $display("  FAIL: dead write gave resp %b, expected SLVERR", bresp); errors=errors+1; end

    $display("6. the bus still works after a timeout");
    do_read(32'h0000_0000, 4'd0, 12'h456, 32'h000A0300);

    $display("");
    $display("errors: %0d", errors);
    if (errors == 0) $display("BRIDGE OK");
    $finish;
  end
  initial begin #500000; $display("TESTBENCH ITSELF TIMED OUT -- the bridge hangs"); $finish; end
endmodule
