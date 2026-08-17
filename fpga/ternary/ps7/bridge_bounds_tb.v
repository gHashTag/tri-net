`timescale 1ns/1ps
// Directed boundary coverage for the AXI3-to-Lite bridge.
//
// The existing bench proves the bridge works and, most importantly, that a dead
// slave cannot hang the CPU. What it does not test is the edges, and two of
// them would fail silently:
//
//   * Byte enables are forwarded, not used, so nothing checked them. A bridge
//     that dropped or inverted s_wstrb would pass every full-word test and
//     corrupt every partial write. The slave here HONOURS wstrb, which is what
//     makes the check possible at all.
//   * Transaction IDs are echoed. Latching the id once instead of per
//     transaction gives the right answer whenever consecutive ids happen to
//     match, which in a single-master system is most of the time.
module lite_slave_be (
  input clk, input rstn,
  input [31:0] awaddr, input awvalid, output reg awready = 0,
  input [31:0] wdata, input [3:0] wstrb, input wvalid, output reg wready = 0,
  output reg bvalid = 0, output reg [1:0] bresp = 0, input bready,
  input dead,
  input [31:0] araddr, input arvalid, output reg arready = 0,
  output reg [31:0] rdata = 0, output reg [1:0] rresp = 0,
  output reg rvalid = 0, input rready);
  reg [31:0] mem [0:63];
  reg [31:0] wa = 0; reg have_a = 0;
  integer i;
  initial for (i=0;i<64;i=i+1) mem[i] = 32'h0;
  always @(posedge clk) begin
    if (!rstn) begin awready<=0; wready<=0; bvalid<=0; arready<=0; rvalid<=0;
                     have_a<=0; end
    else begin
      awready <= awvalid & ~awready & ~have_a;
      if (awvalid & awready) begin wa <= awaddr; have_a <= 1; end
      wready <= wvalid & ~wready & have_a & ~bvalid;
      if (wvalid & wready) begin
        // byte enables honoured, one byte at a time
        if (wstrb[0]) mem[wa[7:2]][ 7: 0] <= wdata[ 7: 0];
        if (wstrb[1]) mem[wa[7:2]][15: 8] <= wdata[15: 8];
        if (wstrb[2]) mem[wa[7:2]][23:16] <= wdata[23:16];
        if (wstrb[3]) mem[wa[7:2]][31:24] <= wdata[31:24];
        bresp <= 0; bvalid <= 1; have_a <= 0;
      end else if (bvalid & bready) bvalid <= 0;
      arready <= arvalid & ~arready & ~rvalid & ~dead;
      if (arvalid & arready) begin rdata <= mem[araddr[7:2]]; rresp <= 0; rvalid <= 1; end
      else if (rvalid & rready) rvalid <= 0;
    end
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

  reg dead = 0;
  lite_slave_be slv (.clk(clk),.rstn(rstn),.dead(dead),
    .awaddr(m_awaddr),.awvalid(m_awvalid),.awready(m_awready),
    .wdata(m_wdata),.wstrb(m_wstrb),.wvalid(m_wvalid),.wready(m_wready),
    .bvalid(m_bvalid),.bresp(m_bresp),.bready(m_bready),
    .araddr(m_araddr),.arvalid(m_arvalid),.arready(m_arready),
    .rdata(m_rdata),.rresp(m_rresp),.rvalid(m_rvalid),.rready(m_rready));

  integer errs = 0, checks = 0, g, n;
  reg [31:0] got;
  reg [11:0] got_id;

  task wr(input [31:0] ad, input [31:0] dt, input [3:0] be, input [11:0] id);
    begin
      @(posedge clk); awaddr<=ad; awlen<=0; awid<=id; awvalid<=1;
      g=0; while(!awready && g<300) begin @(posedge clk); g=g+1; end
      @(posedge clk); awvalid<=0;
      wdata<=dt; wstrb<=be; wlast<=1; wvalid<=1;
      g=0; while(!wready && g<300) begin @(posedge clk); g=g+1; end
      @(posedge clk); wvalid<=0; bready<=1;
      g=0; while(!bvalid && g<2000) begin @(posedge clk); g=g+1; end
      got_id = bid;
      @(posedge clk); bready<=0;
    end
  endtask
  task rd(input [31:0] ad, input [11:0] id);
    begin
      @(posedge clk); araddr<=ad; arlen<=0; arid<=id; arvalid<=1;
      g=0; while(!arready && g<300) begin @(posedge clk); g=g+1; end
      @(posedge clk); arvalid<=0; rready<=1;
      g=0; while(!rvalid && g<2000) begin @(posedge clk); g=g+1; end
      got = rdata; got_id = rid;
      @(posedge clk); rready<=0;
    end
  endtask
  task expect(input [255:0] what, input [31:0] a, input [31:0] b);
    begin
      checks = checks + 1;
      if (a !== b) begin
        $display("  FAIL %0s: got %h, expected %h", what, a, b);
        errs = errs + 1;
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk); rstn <= 1; repeat (4) @(posedge clk);

    $display("1. byte enables reach the slave unchanged");
    wr(32'h00, 32'hFFFFFFFF, 4'hF, 12'h001);
    rd(32'h00, 12'h001); expect("full word", got, 32'hFFFFFFFF);
    wr(32'h00, 32'h000000AA, 4'h1, 12'h002);
    rd(32'h00, 12'h002); expect("byte 0 only", got, 32'hFFFFFFAA);
    wr(32'h00, 32'h00BB0000, 4'h4, 12'h003);
    rd(32'h00, 12'h003); expect("byte 2 only", got, 32'hFFBBFFAA);
    wr(32'h00, 32'hCCDD0000, 4'hC, 12'h004);
    rd(32'h00, 12'h004); expect("upper halfword", got, 32'hCCDDFFAA);
    wr(32'h04, 32'hDEADBEEF, 4'h0, 12'h005);
    rd(32'h04, 12'h005); expect("no byte enabled writes nothing", got, 32'h0);

    $display("2. the transaction id is echoed per transaction, not latched once");
    for (n = 0; n < 6; n = n + 1) begin
      wr(32'h08, 32'h1000 + n, 4'hF, 12'h100 + n*12'h37);
      checks = checks + 1;
      if (got_id !== (12'h100 + n*12'h37)) begin
        $display("  FAIL write id: got %h, expected %h", got_id, 12'h100+n*12'h37);
        errs = errs + 1;
      end
      rd(32'h08, 12'h700 - n*12'h41);
      checks = checks + 1;
      if (got_id !== (12'h700 - n*12'h41)) begin
        $display("  FAIL read id: got %h, expected %h", got_id, 12'h700-n*12'h41);
        errs = errs + 1;
      end
    end

    $display("3. back-to-back with no idle cycle between transactions");
    for (n = 0; n < 8; n = n + 1) wr(32'h0C, 32'hA000 + n, 4'hF, 12'h0);
    rd(32'h0C, 12'h0); expect("last of eight", got, 32'hA007);

    $display("4. the maximum burst this interface can express");
    @(posedge clk); awaddr<=32'h20; awlen<=4'hF; awid<=12'hABC; awvalid<=1;
    g=0; while(!awready && g<300) begin @(posedge clk); g=g+1; end
    @(posedge clk); awvalid<=0;
    for (n = 0; n < 16; n = n + 1) begin
      wdata<=32'hB000+n; wstrb<=4'hF; wlast<=(n==15); wvalid<=1;
      g=0; while(!wready && g<300) begin @(posedge clk); g=g+1; end
      @(posedge clk);
    end
    wvalid<=0; bready<=1;
    g=0; while(!bvalid && g<3000) begin @(posedge clk); g=g+1; end
    checks = checks + 1;
    if (g >= 3000) begin $display("  FAIL 16-beat burst never completed"); errs=errs+1; end
    @(posedge clk); bready<=0;

    $display("5. a slave that never answers must not hang the bus");
    // The matrix showed this caught by exactly one bench. Two now: a fault
    // class with a single check is a single point of failure.
    dead = 1;
    @(posedge clk); araddr<=32'h30; arlen<=0; arid<=12'h5A5; arvalid<=1;
    g=0; while(!arready && g<300) begin @(posedge clk); g=g+1; end
    @(posedge clk); arvalid<=0; rready<=1;
    g=0; while(!rvalid && g<4000) begin @(posedge clk); g=g+1; end
    checks = checks + 1;
    if (g >= 4000) begin
      $display("  FAIL the read never completed -- the hang that costs a power cycle");
      errs = errs + 1;
    end else if (rresp !== 2'b10) begin
      $display("  FAIL expected SLVERR from the timeout, got rresp %b", rresp);
      errs = errs + 1;
    end
    @(posedge clk); rready<=0;
    dead = 0;
    repeat (10) @(posedge clk);

    $display("6. and the bus still works afterwards");
    wr(32'h34, 32'hFEEDFACE, 4'hF, 12'h111);
    rd(32'h34, 12'h111); expect("after a timeout", got, 32'hFEEDFACE);

    $display("");
    $display("checks = %0d", checks);
    $display("failures = %0d", errs);
    if (errs == 0) $display("BRIDGE BOUNDS OK");
    $finish;
  end
  initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
