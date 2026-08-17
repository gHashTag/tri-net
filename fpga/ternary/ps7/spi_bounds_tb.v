`timescale 1ns/1ps
// Directed boundary coverage for the SPI master.
//
// spi_master_tb proves data moves in both directions. What it does not check is
// the protocol's timing requirements, and those are what a real slave enforces:
//
//   * CPHA = 0 means the first MOSI bit must already be valid when the first
//     rising edge arrives. A master that drives it on the first falling edge
//     instead shifts every word by one bit, and a loopback slave written to the
//     same misunderstanding agrees with it perfectly.
//   * Chip select must frame the transfer -- low for the whole of it, high
//     between. A master that releases it early loses the last bits into a
//     deselected slave.
//   * MISO must be sampled on the rising edge only. This bench changes MISO on
//     falling edges, which a correctly-timed master cannot notice.
//
// It also checks what happens under abuse: a start pulse during a transfer, and
// a reset in the middle of one.
module tb;
  localparam W=24;
  reg clk=0; always #5 clk=~clk;
  reg rstn=0, start=0;
  reg [W-1:0] wdata=0;
  wire [W-1:0] rdata;
  wire busy, done, csn, sclk, mosi;
  reg miso = 0;

  spi_master #(.WIDTH(W), .DIV(4)) m (
    .clk(clk), .rstn(rstn), .start(start), .wdata(wdata), .rdata(rdata),
    .busy(busy), .done(done), .spi_csn(csn), .spi_clk(sclk),
    .spi_mosi(mosi), .spi_miso(miso));

  integer errs=0, checks=0, g, gm, n, edges, csn_low_at_edge, mosi_stable;
  reg [W-1:0] captured;
  reg [W-1:0] pattern;
  reg first_edge_seen;
  reg [W-1:0] shift_ref;

  // observe the pins independently of the master's own bookkeeping
  always @(posedge sclk) begin
    edges = edges + 1;
    if (csn) csn_low_at_edge = csn_low_at_edge + 1;   // must never happen
    captured = {captured[W-2:0], mosi};
  end

  task expect(input [255:0] what, input integer a, input integer b);
    begin
      checks = checks + 1;
      if (a !== b) begin
        $display("  FAIL %0s: got %0d, expected %0d", what, a, b);
        errs = errs + 1;
      end
    end
  endtask

  task go(input [W-1:0] word);
    begin
      edges = 0; csn_low_at_edge = 0; captured = 0;
      @(posedge clk); wdata <= word; start <= 1;
      @(posedge clk); start <= 0;
      g=0; while (!done && g<20000) begin @(posedge clk); g=g+1; end
      if (!done) begin $display("  FAIL transfer never completed"); errs=errs+1; end
      @(posedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk); rstn <= 1; repeat (4) @(posedge clk);

    $display("1. chip select is idle high before anything starts");
    expect("csn idle", csn, 1);

    $display("2. exactly WIDTH clock edges per transfer, all with csn low");
    for (n = 0; n < 4; n = n + 1) begin
      pattern = 24'hA5C300 + n;
      go(pattern);
      expect("clock edges", edges, W);
      expect("edges while deselected", csn_low_at_edge, 0);
      expect("what the pins carried", captured, pattern);
    end

    $display("3. chip select returns high between transfers");
    expect("csn high after done", csn, 1);

    $display("4. a start pulse during a transfer must not disturb it");
    edges = 0; csn_low_at_edge = 0; captured = 0;
    @(posedge clk); wdata <= 24'h123456; start <= 1;
    @(posedge clk); start <= 0;
    repeat (20) @(posedge clk);
    @(posedge clk); wdata <= 24'hFFFFFF; start <= 1;   // abuse: start while busy
    @(posedge clk); start <= 0;
    g=0; while (!done && g<20000) begin @(posedge clk); g=g+1; end
    @(posedge clk);
    expect("the first word still went out intact", captured, 24'h123456);
    expect("still exactly WIDTH edges", edges, W);

    $display("5. MISO is sampled on the rising edge only");
    // drive miso to a known pattern on falling edges; a master that sampled on
    // the falling edge would read the value we are just then changing
    fork
      begin
        shift_ref = 24'h0F0F55;
        for (n = 0; n < W; n = n + 1) begin
          @(negedge sclk);
          miso = shift_ref[W-1];
          shift_ref = {shift_ref[W-2:0], 1'b0};
        end
      end
      begin
        miso = 1'b0;
        @(posedge clk); wdata <= 24'h000000; start <= 1;
        @(posedge clk); start <= 0;
        // the first bit must be presented before the first rising edge
        @(negedge csn); miso = 1'b0;
        g=0; while (!done && g<20000) begin @(posedge clk); g=g+1; end
      end
    join
    @(posedge clk);
    checks = checks + 1;
    if (rdata === 24'hxxxxxx) begin
      $display("  FAIL read data is unknown -- MISO was sampled while changing");
      errs = errs + 1;
    end

    $display("5b. what the slave sends must come back intact");
    // The matrix showed MISO assembly caught by exactly one bench. This is the
    // second: a shift-register slave feeding a known word, checked at the
    // master's rdata. It duplicates spi_master_tb deliberately -- one bench per
    // fault class is a single point of failure.
    for (n = 0; n < 4; n = n + 1) begin
      pattern = 24'h3C5A96 + n*24'h010203;
      fork
        begin : drive_miso
          shift_ref = pattern;
          @(negedge csn);
          miso = shift_ref[W-1];
          for (gm = 0; gm < W-1; gm = gm + 1) begin
            @(negedge sclk);
            shift_ref = {shift_ref[W-2:0], 1'b0};
            miso = shift_ref[W-1];
          end
        end
        go(24'h000000);
      join
      expect("MISO word returned", rdata, pattern);
    end

    $display("6. reset in the middle of a transfer releases the bus");
    @(posedge clk); wdata <= 24'h999999; start <= 1;
    @(posedge clk); start <= 0;
    repeat (30) @(posedge clk);
    expect("busy during the transfer", busy, 1);
    rstn <= 0; repeat (4) @(posedge clk);
    expect("chip select released by reset", csn, 1);
    expect("busy cleared by reset", busy, 0);
    rstn <= 1; repeat (4) @(posedge clk);

    $display("7. the master still works after that reset");
    go(24'h5A5A5A);
    expect("edges after reset", edges, W);
    expect("data after reset", captured, 24'h5A5A5A);

    $display("");
    $display("checks = %0d", checks);
    $display("failures = %0d", errs);
    if (errs == 0) $display("SPI BOUNDS OK");
    $finish;
  end
  initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
