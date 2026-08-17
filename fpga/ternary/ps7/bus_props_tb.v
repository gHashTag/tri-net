`timescale 1ns/1ps
// Continuous property monitors, as a second mechanism rather than a second
// instance of the first.
//
// The transaction benches check what happened at the points they thought to
// look. A monitor watches every clock, so it catches a violation wherever it
// occurs -- including in traffic written to exercise something else entirely.
// The coverage matrix showed two fault classes resting on one bench each; this
// is a different way of seeing the same two, so losing either bench no longer
// blinds the suite to them.
//
// Everything here is an invariant, not a scenario:
//
//   handshake     a VALID once raised may not drop, and its payload may not
//                 change, until READY -- on every channel, both sides
//   response      no B or R without a request that earned it
//   byte enables  m_wstrb must equal the s_wstrb of the beat being forwarded
//   write id      s_bid must be the s_awid of the write being answered
//   chip select   spi_csn low implies the master is busy
//   spi clock     spi_clk must not move while spi_csn is high
//   reset         !rstn implies spi_csn high
module lite_slave_p (
  input clk, input rstn, input [7:0] stall,
  input [31:0] awaddr, input awvalid, output reg awready = 0,
  input [31:0] wdata, input [3:0] wstrb, input wvalid, output reg wready = 0,
  output reg bvalid = 0, output reg [1:0] bresp = 0, input bready,
  input [31:0] araddr, input arvalid, output reg arready = 0,
  output reg [31:0] rdata = 0, output reg [1:0] rresp = 0,
  output reg rvalid = 0, input rready);
  reg [31:0] mem [0:63];
  reg [31:0] wa = 0; reg have_a = 0;
  integer i;
  initial for (i=0;i<64;i=i+1) mem[i] = 32'h0;
  always @(posedge clk) begin
    if (!rstn) begin awready<=0; wready<=0; bvalid<=0; arready<=0; rvalid<=0; have_a<=0; end
    else begin
      awready <= awvalid & ~awready & ~have_a & ~stall[0];
      if (awvalid & awready) begin wa <= awaddr; have_a <= 1; end
      wready <= wvalid & ~wready & have_a & ~bvalid & ~stall[1];
      if (wvalid & wready) begin
        if (wstrb[0]) mem[wa[7:2]][ 7: 0] <= wdata[ 7: 0];
        if (wstrb[1]) mem[wa[7:2]][15: 8] <= wdata[15: 8];
        if (wstrb[2]) mem[wa[7:2]][23:16] <= wdata[23:16];
        if (wstrb[3]) mem[wa[7:2]][31:24] <= wdata[31:24];
        bresp <= 0; bvalid <= 1; have_a <= 0;
      end else if (bvalid & bready) bvalid <= 0;
      arready <= arvalid & ~arready & ~rvalid & ~stall[2];
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

  axi3_to_lite #(.TIMEOUT(64)) br (.clk(clk),.rstn(rstn),
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
  reg [7:0] stall = 0;
  lite_slave_p slv (.clk(clk),.rstn(rstn),.stall(stall),
    .awaddr(m_awaddr),.awvalid(m_awvalid),.awready(m_awready),
    .wdata(m_wdata),.wstrb(m_wstrb),.wvalid(m_wvalid),.wready(m_wready),
    .bvalid(m_bvalid),.bresp(m_bresp),.bready(m_bready),
    .araddr(m_araddr),.arvalid(m_arvalid),.arready(m_arready),
    .rdata(m_rdata),.rresp(m_rresp),.rvalid(m_rvalid),.rready(m_rready));

  reg srstn=0, sstart=0; reg [23:0] swdata=0;
  wire [23:0] srdata; wire sbusy, sdone, scsn, ssclk, smosi;
  reg smiso = 0;
  spi_master #(.WIDTH(24), .DIV(4)) sp (
    .clk(clk), .rstn(srstn), .start(sstart), .wdata(swdata), .rdata(srdata),
    .busy(sbusy), .done(sdone), .spi_csn(scsn), .spi_clk(ssclk),
    .spi_mosi(smosi), .spi_miso(smiso));

  integer viol = 0, obs = 0;
  reg [3:0] pending_strb = 4'hF;
  reg       have_pending = 0;
  reg [11:0] pending_id = 0;
  reg        id_pending = 0;
  reg        last_sclk = 0;
  reg        last_csn = 1;
  reg        last_srstn = 0;

  // Handshake stability, and the formulation is the whole difficulty.
  //
  // "VALID may not drop until READY" is too strong: once the handshake has
  // happened, VALID may legitimately stay up another cycle and then fall, and
  // a monitor that only looks one edge back reads that as a withdrawal. The
  // property is that VALID may not drop while the transfer it is asking for
  // has NOT yet been accepted -- so each channel carries a flag saying whether
  // this assertion has been served.
  //
  // Three monitors in this file were a cycle too strict before they were
  // right, each time declaring correct hardware faulty. A property stated
  // tighter than the design's own timing is not a stricter test, it is a
  // wrong one.
  reg        aw_served = 0, w_served = 0, ar_served = 0;
  reg        p_awv = 0, p_wv = 0, p_arv = 0;
  reg [31:0] p_awa = 0, p_wd = 0, p_ara = 0;
  reg [3:0]  p_ws = 0;
  reg [11:0] p_awi = 0, p_ari = 0;
  reg        maw_served = 0, mw_served = 0, mar_served = 0;
  reg        b_taken = 0, r_taken = 0;
  reg        p_maw = 0, p_mw = 0, p_mar = 0;
  reg [31:0] p_mawa = 0, p_mwd = 0, p_mara = 0;
  reg [3:0]  p_mws = 0;
  reg        p_bv = 0, p_rv = 0;
  integer    writes_started = 0, writes_answered = 0;
  integer    reads_started = 0, reads_answered = 0;

  task violation(input [511:0] what);
    begin
      if (viol < 6) $display("  VIOLATION: %0s", what);
      viol = viol + 1;
    end
  endtask

  // record what the processor asked for, then check what the bridge forwarded
  always @(posedge clk) if (rstn) begin
    if (wvalid && wready) begin pending_strb <= wstrb; have_pending <= 1; end
    if (awvalid && awready) begin pending_id <= awid; id_pending <= 1; end
    if (m_wvalid && m_wready) begin
      obs = obs + 1;
      if (have_pending && m_wstrb !== pending_strb)
        violation("m_wstrb does not match the s_wstrb of this beat");
      have_pending <= 0;
    end
    if (bvalid && bready) begin
      obs = obs + 1;
      if (id_pending && bid !== pending_id)
        violation("s_bid is not the s_awid of the write being answered");
      id_pending <= 0;
    end
    // ---- AXI handshake stability, processor side ----
    if (p_awv && !aw_served) begin
      obs = obs + 1;
      if (!awvalid) violation("s_awvalid withdrawn before it was accepted");
      else if (awaddr !== p_awa || awid !== p_awi)
        violation("s_aw payload changed while waiting for ready");
    end
    if (p_wv && !w_served) begin
      obs = obs + 1;
      if (!wvalid) violation("s_wvalid withdrawn before it was accepted");
      else if (wdata !== p_wd || wstrb !== p_ws)
        violation("s_w payload changed while waiting for ready");
    end
    if (p_arv && !ar_served) begin
      obs = obs + 1;
      if (!arvalid) violation("s_arvalid withdrawn before it was accepted");
      else if (araddr !== p_ara || arid !== p_ari)
        violation("s_ar payload changed while waiting for ready");
    end
    aw_served <= awvalid ? (aw_served | awready) : 1'b0;
    w_served  <= wvalid  ? (w_served  | wready)  : 1'b0;
    ar_served <= arvalid ? (ar_served | arready) : 1'b0;
    p_awv <= awvalid; p_awa <= awaddr; p_awi <= awid;
    p_wv  <= wvalid;  p_wd  <= wdata;  p_ws  <= wstrb;
    p_arv <= arvalid; p_ara <= araddr; p_ari <= arid;

    // ---- and the same rules on the side the bridge drives ----
    if (p_maw && !maw_served) begin
      obs = obs + 1;
      if (!m_awvalid) violation("m_awvalid withdrawn before acceptance");
      else if (m_awaddr !== p_mawa)
        violation("m_awaddr changed while waiting for ready");
    end
    if (p_mw && !mw_served) begin
      obs = obs + 1;
      if (!m_wvalid) violation("m_wvalid withdrawn before acceptance");
      else if (m_wdata !== p_mwd || m_wstrb !== p_mws)
        violation("m_w payload changed while waiting for ready");
    end
    if (p_mar && !mar_served) begin
      obs = obs + 1;
      if (!m_arvalid) violation("m_arvalid withdrawn before acceptance");
      else if (m_araddr !== p_mara)
        violation("m_araddr changed while waiting for ready");
    end
    maw_served <= m_awvalid ? (maw_served | m_awready) : 1'b0;
    mw_served  <= m_wvalid  ? (mw_served  | m_wready)  : 1'b0;
    mar_served <= m_arvalid ? (mar_served | m_arready) : 1'b0;
    p_maw <= m_awvalid; p_mawa <= m_awaddr;
    p_mw  <= m_wvalid;  p_mwd  <= m_wdata; p_mws <= m_wstrb;
    p_mar <= m_arvalid; p_mara <= m_araddr;

    // ---- a response must be earned, and arrive once ----
    if (awvalid && awready) writes_started = writes_started + 1;
    if (bvalid && bready) begin
      writes_answered = writes_answered + 1;
      obs = obs + 1;
      if (writes_answered > writes_started)
        violation("a write response arrived that no write had asked for");
    end
    if (arvalid && arready) reads_started = reads_started + 1;
    if (rvalid && rready) begin
      reads_answered = reads_answered + 1;
      obs = obs + 1;
      if (reads_answered > reads_started)
        violation("a read response arrived that no read had asked for");
    end
    // a response, once raised, must also hold until taken
    if (p_bv && !b_taken) begin
      obs = obs + 1;
      if (!bvalid) violation("s_bvalid withdrawn before the master took it");
    end
    if (p_rv && !r_taken) begin
      obs = obs + 1;
      if (!rvalid) violation("s_rvalid withdrawn before the master took it");
    end
    b_taken <= bvalid ? (b_taken | bready) : 1'b0;
    r_taken <= rvalid ? (r_taken | rready) : 1'b0;
    p_bv <= bvalid;
    p_rv <= rvalid;

    // SPI invariants
    obs = obs + 1;
    if (!scsn && !sbusy) violation("chip select low while the master is idle");
    last_sclk <= ssclk;
    last_csn  <= scsn;
    // Both edges must be inside a sustained deselected period. The master
    // releases chip select and drops the clock on the same edge, which is
    // correct -- flagging that is the monitor being a cycle out, not the design
    // being wrong.
    if (scsn && last_csn && (ssclk !== last_sclk))
      violation("spi_clk moved during a sustained deselected period");
    // The reset is synchronous, so it acts on the following edge -- requiring
    // chip select to be high in the same cycle the reset arrives asks for
    // something no synchronous design can do. The property is that it is
    // released within a cycle, and stays released.
    last_srstn <= srstn;
    if (!srstn && !last_srstn && !scsn)
      violation("chip select still low a cycle after reset was asserted");
  end

  integer g, n, rseed = 12345;
  // Coverage bins. Counting observations says how much traffic ran; these say
  // which STATES it reached. A run with three thousand observations that never
  // stalls the write channel has not tested waiting on the write channel, and
  // the difference is invisible in a total.
  reg cov_aw_stall = 0, cov_w_stall = 0, cov_ar_stall = 0;
  reg cov_overlap = 0, cov_b_wait = 0, cov_r_wait = 0;
  reg cov_strb [0:15];
  reg cov_spi_reset = 0, cov_spi_b2b = 0;
  reg spi_just_done = 0;
  // Cross bins. A single bin says a state was reached; a cross bin says two
  // were reached AT ONCE, which is where the interesting failures live -- a
  // channel stalling is ordinary, a channel stalling while the other one holds
  // an unacknowledged response is the case nobody wrote a scenario for.
  reg cx_aw_stall_rd = 0;    // write address waiting while a read is in flight
  reg cx_w_stall_rd = 0;     // write data waiting while a read is in flight
  reg cx_bwait_arstall = 0;  // response held while a read address waits
  reg cx_both_wait = 0;      // both responses held at once
  reg cx_spi_bus = 0;        // SPI transfer while the bus is under backpressure
  reg cx_spireset_bus = 0;   // SPI reset mid-transfer while the bus stalls
  reg cx_partial_stall = 0;  // a partial-strobe write that had to wait

  // Harder bins. The pair bins above are hit on nearly every seed, so they
  // discriminate little. These require three things at once, or one thing
  // sustained -- states a random walk reaches rarely if at all. The point of
  // raising the bar is to find what the traffic CANNOT reach; a bin that
  // always fills measures nothing.
  reg cx3_partial_both_wait = 0;   // partial write stalled, both responses held
  reg cx3_spi_reset_both = 0;      // SPI reset while both responses held
  reg cx_long_aw_stall = 0;        // write address waiting four cycles running
  reg cx_long_w_stall = 0;         // write data waiting four cycles running
  reg cx_long_b_wait = 0;          // response held four cycles running
  integer aw_run = 0, w_run = 0, b_run = 0;
  integer ci;
  integer stall_cycles = 0, overlap_cycles = 0, gap_cycles = 0;
  // Randomised backpressure. Without it the slave always answers on the next
  // cycle and the "waiting for ready" half of every invariant is never
  // exercised -- the monitors would run clean over traffic that cannot break
  // them, which is the vacuity this suite keeps finding in its own checks.
  always @(posedge clk) if (rstn) begin
    rseed = (rseed*1103515245 + 12345) & 32'h7FFFFFFF;
    stall <= {5'd0, rseed[19], rseed[18], rseed[17]};
    if (|stall) stall_cycles = stall_cycles + 1;
    if (awvalid && !awready) cov_aw_stall <= 1;
    if (wvalid  && !wready)  cov_w_stall  <= 1;
    if (arvalid && !arready) cov_ar_stall <= 1;
    if (bvalid && !bready)   cov_b_wait   <= 1;
    if (rvalid && !rready)   cov_r_wait   <= 1;
    if (wvalid && wready)    cov_strb[wstrb] <= 1;

    if (awvalid && !awready && (arvalid || rvalid)) cx_aw_stall_rd <= 1;
    if (wvalid  && !wready  && (arvalid || rvalid)) cx_w_stall_rd  <= 1;
    if (bvalid && !bready && arvalid && !arready)   cx_bwait_arstall <= 1;
    if (bvalid && !bready && rvalid && !rready)     cx_both_wait <= 1;
    if (sbusy && (|stall))                          cx_spi_bus <= 1;
    if (!srstn && sbusy && (|stall))                cx_spireset_bus <= 1;
    if (wvalid && !wready && (wstrb != 4'hF))       cx_partial_stall <= 1;

    if (wvalid && !wready && (wstrb != 4'hF) && bvalid && !bready
        && rvalid && !rready)                       cx3_partial_both_wait <= 1;
    if (!srstn && sbusy && bvalid && !bready
        && rvalid && !rready)                       cx3_spi_reset_both <= 1;
    aw_run = (awvalid && !awready) ? aw_run + 1 : 0;
    w_run  = (wvalid  && !wready)  ? w_run  + 1 : 0;
    b_run  = (bvalid  && !bready)  ? b_run  + 1 : 0;
    if (aw_run >= 4) cx_long_aw_stall <= 1;
    if (w_run  >= 4) cx_long_w_stall  <= 1;
    if (b_run  >= 4) cx_long_b_wait   <= 1;
    if ((awvalid | wvalid) && arvalid) begin
      overlap_cycles = overlap_cycles + 1;
      cov_overlap <= 1;
    end
    if (!srstn && sbusy) cov_spi_reset <= 1;
    // "back to back" means a new transfer begins with no idle cycle between,
    // which in procedural code cannot be the same edge as done -- so the bin
    // is stated as what is actually achievable and meaningful.
    spi_just_done <= sdone;
    if (sstart && (sdone | spi_just_done)) cov_spi_b2b <= 1;
    if (!awvalid && !wvalid && !arvalid) gap_cycles = gap_cycles + 1;
  end

  integer g2, pa, pw, pb, pr, pc, ps;

  task rd(input [31:0] ad, input [11:0] id);
    begin
      @(posedge clk); araddr<=ad; arlen<=0; arid<=id; arvalid<=1;
      g=0; while(!arready && g<300) begin @(posedge clk); g=g+1; end
      @(posedge clk); arvalid<=0; rready<=0;
      g=0; while(!rvalid && g<2000) begin @(posedge clk); g=g+1; end
      if (rseed[11]) repeat (2 + rseed[13:12]) @(posedge clk);
      rready<=1;
      @(posedge clk); rready<=0;
    end
  endtask
  task wr(input [31:0] ad, input [31:0] dt, input [3:0] be, input [11:0] id);
    begin
      @(posedge clk); awaddr<=ad; awlen<=0; awid<=id; awvalid<=1;
      g=0; while(!awready && g<300) begin @(posedge clk); g=g+1; end
      @(posedge clk); awvalid<=0;
      wdata<=dt; wstrb<=be; wlast<=1; wvalid<=1;
      g=0; while(!wready && g<300) begin @(posedge clk); g=g+1; end
      @(posedge clk); wvalid<=0; bready<=0;
      // Wait for the response WITH bready low, then hold it there a while.
      // Delaying before the response arrives does nothing -- by the time it
      // comes the master is already ready, and the invariant about a response
      // held across cycles is never exercised. Twenty-four seeds missed it.
      g=0; while(!bvalid && g<2000) begin @(posedge clk); g=g+1; end
      if (rseed[7]) repeat (2 + rseed[9:8]) @(posedge clk);
      bready<=1;
      @(posedge clk); bready<=0;
    end
  endtask

  initial begin
    for (ci = 0; ci < 16; ci = ci + 1) cov_strb[ci] = 0;
    if (!$value$plusargs("seed=%d", rseed)) rseed = 12345;
    repeat (4) @(posedge clk); rstn <= 1; srstn <= 1; repeat (4) @(posedge clk);

    // ordinary traffic: the monitors do the checking, not the traffic
    // Reads as well as writes: a monitor on a channel that never carries a
    // transaction observes nothing and proves nothing, which is the same
    // vacuity this suite has now caught in four other places.
    // Writes and reads driven by independent processes, so the two address
    // channels overlap instead of taking turns. Scripted alternation never
    // puts a read request up while a write is still waiting for ready, and
    // that is exactly the state the stability invariants are about.
    fork
      begin : writer
        for (n = 0; n < 40; n = n + 1) begin
          wr(32'h40 + (n%8)*4, 32'h1000_0000 + n, n[3:0], 12'h200 + n*12'h13);
          repeat (rseed[3:2]) @(posedge clk);
        end
      end
      begin : reader
        repeat (7) @(posedge clk);
        for (g2 = 0; g2 < 40; g2 = g2 + 1) begin
          rd(32'h40 + (g2%8)*4, 12'h300 + g2*12'h17);
          repeat (rseed[5:4]) @(posedge clk);
        end
      end
    join

    for (n = 0; n < 6; n = n + 1) begin
      @(posedge clk); swdata <= 24'h100000 + n; sstart <= 1;
      @(posedge clk); sstart <= 0;
      g=0; while (!sdone && g<20000) begin @(posedge clk); g=g+1; end
      @(posedge clk);
    end

    // ---- pipelined phase ----
    // The scripted tasks above wait for each response before issuing the next
    // request, so no queue ever forms at the bridge and the processor-facing
    // channels never stall for long. Here each channel has exactly ONE driver
    // and none of them waits for another -- which is what creates the queue,
    // and is also why this cannot deadlock the way the two-writer attempt in
    // the previous cycle did.
    fork
      begin : aw_driver
        for (pa = 0; pa < 24; pa = pa + 1) begin
          @(posedge clk);
          awaddr <= 32'h60 + (pa % 6) * 4; awid <= 12'h700 + pa; awlen <= 0;
          awvalid <= 1;
          @(posedge clk);
          while (!awready) @(posedge clk);
          awvalid <= 0;
        end
        @(posedge clk); awvalid <= 0;
      end
      begin : w_driver
        for (pw = 0; pw < 24; pw = pw + 1) begin
          @(posedge clk);
          wdata <= 32'hC000_0000 + pw;
          wstrb <= (pw % 3 == 0) ? 4'h3 : ((pw % 3 == 1) ? 4'hC : 4'hF);
          wlast <= 1; wvalid <= 1;
          @(posedge clk);
          while (!wready) @(posedge clk);
          wvalid <= 0;
        end
        @(posedge clk); wvalid <= 0;
      end
      begin : b_collector
        for (pb = 0; pb < 24; pb = pb + 1) begin
          @(posedge clk); bready <= 0;
          while (!bvalid) @(posedge clk);
          repeat (10 + (pb % 5)) @(posedge clk);  // hold it long enough that
                                                 // the SPI reset can land
                                                 // inside the window
          bready <= 1;
          @(posedge clk); bready <= 0;
        end
      end
      begin : ar_driver
        repeat (3) @(posedge clk);
        for (pr = 0; pr < 24; pr = pr + 1) begin
          @(posedge clk);
          araddr <= 32'h60 + (pr % 6) * 4; arid <= 12'h800 + pr; arlen <= 0;
          arvalid <= 1;
          @(posedge clk);
          while (!arready) @(posedge clk);
          arvalid <= 0;
        end
        @(posedge clk); arvalid <= 0;
      end
      begin : r_collector
        for (pc = 0; pc < 24; pc = pc + 1) begin
          @(posedge clk); rready <= 0;
          while (!rvalid) @(posedge clk);
          repeat (10 + (pc % 5)) @(posedge clk);
          rready <= 1;
          @(posedge clk); rready <= 0;
        end
      end
      begin : spi_alongside
        for (ps = 0; ps < 5; ps = ps + 1) begin
          @(posedge clk); swdata <= 24'h400000 + ps; sstart <= 1;
          @(posedge clk); sstart <= 0;
          repeat (6) @(posedge clk);
          if (ps == 2) begin
            // Aim at the state rather than hope for it. A reset that happens
            // to coincide with both responses held is rare enough that 24
            // random seeds never produced it; waiting for the condition and
            // then resetting is targeted stimulus, which is what a rare cross
            // bin needs. It is still the design under test that must survive
            // it.
            // The bin needs the master still BUSY when the reset lands, so
            // the search must stay inside the transfer -- roughly 24 bits at
            // eight clocks each. Looking for the condition after the transfer
            // ended is why the previous attempt never filled this bin.
            g=0;
            while (sbusy && !(bvalid && !bready && rvalid && !rready)
                   && g<180) begin
              @(posedge clk); g=g+1;
            end
            if (sbusy) begin
              srstn <= 0; repeat (3) @(posedge clk); srstn <= 1;
            end
          end
          g=0; while (!sdone && !sbusy && g<400) begin @(posedge clk); g=g+1; end
          g=0; while (sbusy && g<20000) begin @(posedge clk); g=g+1; end
        end
      end
    join
    repeat (20) @(posedge clk);

    // a reset in the middle of a transfer, watched rather than sampled
    @(posedge clk); swdata <= 24'hABCDEF; sstart <= 1;
    @(posedge clk); sstart <= 0;
    repeat (25) @(posedge clk);
    srstn <= 0; repeat (8) @(posedge clk);
    srstn <= 1; repeat (8) @(posedge clk);

    for (n = 0; n < 4; n = n + 1) begin
      @(posedge clk); swdata <= 24'h200000 + n; sstart <= 1;
      @(posedge clk); sstart <= 0;
      g=0; while (!sdone && g<20000) begin @(posedge clk); g=g+1; end
      @(posedge clk);
    end

    // Back-to-back: raise start in the very cycle done fires, with no idle
    // between transfers. The master must either take it or ignore it cleanly;
    // either way the state has to be visited before it can be claimed tested.
    for (n = 0; n < 4; n = n + 1) begin
      swdata <= 24'h300000 + n; sstart <= 1;
      @(posedge clk); sstart <= 0;
      g=0;
      while (!sdone && g<20000) begin @(posedge clk); g=g+1; end
      swdata <= 24'h310000 + n; sstart <= 1;   // same cycle as done
      @(posedge clk); sstart <= 0;
      g=0; while (!sdone && g<20000) begin @(posedge clk); g=g+1; end
      @(posedge clk);
    end

    repeat (20) @(posedge clk);
    $display("writes started %0d, answered %0d", writes_started, writes_answered);
    $display("reads started %0d, answered %0d", reads_started, reads_answered);
    if (writes_answered !== writes_started)
      violation("not every accepted write was answered exactly once");
    $display("cycles with backpressure = %0d", stall_cycles);
    $display("cycles with read and write both outstanding = %0d", overlap_cycles);
    $display("idle cycles = %0d", gap_cycles);
    $write("COVERAGE");
    if (cov_aw_stall)  $write(" aw_stall");
    if (cov_w_stall)   $write(" w_stall");
    if (cov_ar_stall)  $write(" ar_stall");
    if (cov_b_wait)    $write(" b_wait");
    if (cov_r_wait)    $write(" r_wait");
    if (cov_overlap)   $write(" overlap");
    if (cov_spi_reset) $write(" spi_reset_mid_transfer");
    if (cov_spi_b2b)   $write(" spi_back_to_back");
    for (ci = 0; ci < 16; ci = ci + 1) if (cov_strb[ci]) $write(" strb%0d", ci);
    if (cx_aw_stall_rd)   $write(" x_awstall_with_read");
    if (cx_w_stall_rd)    $write(" x_wstall_with_read");
    if (cx_bwait_arstall) $write(" x_bwait_with_arstall");
    if (cx_both_wait)     $write(" x_both_responses_waiting");
    if (cx_spi_bus)       $write(" x_spi_during_bus_stall");
    if (cx_spireset_bus)  $write(" x_spireset_during_bus_stall");
    if (cx_partial_stall) $write(" x_partial_write_stalled");
    if (cx3_partial_both_wait) $write(" x3_partial_with_both_responses_held");
    if (cx3_spi_reset_both)    $write(" x3_spireset_with_both_responses_held");
    if (cx_long_aw_stall)      $write(" x_aw_stalled_four_cycles");
    if (cx_long_w_stall)       $write(" x_w_stalled_four_cycles");
    if (cx_long_b_wait)        $write(" x_response_held_four_cycles");
    $write("\n");
    $display("observations = %0d", obs);
    $display("violations = %0d", viol);
    if (reads_started == 0 || writes_started == 0)
      $display("  VACUOUS: a channel carried no traffic, monitors saw nothing");
    else if (stall_cycles == 0)
      $display("  VACUOUS: the slave never stalled, so no invariant about waiting was tested");
    else if (overlap_cycles == 0)
      $display("  VACUOUS: read and write never overlapped");
    else if (viol == 0 && obs > 500) $display("BUS PROPERTIES OK");
    $finish;
  end
  initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
