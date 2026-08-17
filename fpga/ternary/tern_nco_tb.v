`timescale 1ns/1ps
// Directed coverage for the modem's transmit side.
//
// tern_loop_tb exercises the NCO only through the correlator, which is a good
// end-to-end statement and a poor diagnostic: a wrong carrier phase and a wrong
// tap order produce the same peak. This checks the generator's own contract.
//
// The carrier is sign(cos(2*pi*k/8)) = [+1,+1,0,-1,-1,-1,0,+1]. Six of the
// eight entries are non-zero, which is why the matched peak is 6*AMP and not
// 8*AMP -- a number worth stating, since it is the one the loop bench asserts.
module tb;
  localparam PACC=24, W=16, AMP=100;
  reg clk=0; always #5 clk=~clk;
  reg rst=1, en=0, data_bit=1;
  reg [PACC-1:0] fword = 0;
  wire signed [W-1:0] sample;
  wire [1:0] tern;
  tern_nco #(.PACC(PACC),.W(W),.AMP(AMP)) u (
    .clk(clk),.rst(rst),.en(en),.fword(fword),.data_bit(data_bit),
    .sample(sample),.tern(tern));

  integer i, errs = 0, checks = 0, nonzero = 0, plus = 0, minus = 0, zero = 0;
  integer expect_[0:7];
  reg [1:0] seen [0:7];
  integer obs [0:7];
  integer r, rot_ok, rot_at, match;
  integer batch1 [0:7];
  integer batch2 [0:7];

  task expect(input [255:0] what, input integer a, input integer b);
    begin
      checks = checks + 1;
      if (a !== b) begin
        $display("  FAIL %0s: got %0d, expected %0d", what, a, b);
        errs = errs + 1;
      end
    end
  endtask

  initial begin
    // sign(cos(2*pi*k/8)) for k = 0..7
    expect_[0]= 1; expect_[1]= 1; expect_[2]= 0; expect_[3]=-1;
    expect_[4]=-1; expect_[5]=-1; expect_[6]= 0; expect_[7]= 1;

    repeat (3) @(posedge clk); rst <= 0; @(posedge clk);

    $display("1. with en low the phase must not advance");
    fword <= (1 << PACC) / 8; en <= 0;
    repeat (8) @(posedge clk);
    expect("sample while disabled", sample, 0);

    $display("2. one carrier period, sample by sample");
    en <= 1; data_bit <= 1;
    @(posedge clk);
    for (i = 0; i < 8; i = i + 1) begin
      @(posedge clk); #1;
      obs[i] = sample;
      if (tern == 2'b01) plus = plus + 1;
      else if (tern == 2'b10) minus = minus + 1;
      else zero = zero + 1;
    end
    // The contract is that the period IS sign(cos(2*pi*k/8)); which entry the
    // sampling happens to start on is not part of it. Checking against a fixed
    // index makes a pipeline delay look like a wrong carrier, which is what the
    // first version of this bench reported.
    rot_ok = 0;
    for (r = 0; r < 8; r = r + 1) begin
      match = 1;
      for (i = 0; i < 8; i = i + 1)
        if (obs[i] !== expect_[(i + r) % 8] * AMP) match = 0;
      if (match) begin rot_ok = 1; rot_at = r; end
    end
    checks = checks + 1;
    if (!rot_ok) begin
      $display("  FAIL the eight samples are not the carrier period in any rotation");
      for (i = 0; i < 8; i = i + 1) $display("      obs[%0d] = %0d", i, obs[i]);
      errs = errs + 1;
    end else
      $display("   period matches the carrier table, starting at entry %0d", rot_at);
    $display("   carrier entries per period: %0d positive, %0d negative, %0d zero",
             plus, minus, zero);
    $display("nonzero_entries = %0d", plus + minus);
    expect("non-zero entries per period", plus + minus, 6);
    expect("positive entries", plus, 3);
    expect("negative entries", minus, 3);
    expect("zero entries", zero, 2);

    $display("3. the data bit inverts the carrier, exactly");
    // Compared period against period, not against an assumed index. With
    // fword = 2^PACC/8 the phase returns to where it started after exactly
    // eight clocks, so batch two lines up with batch one whatever the phase
    // happened to be -- an absolute index check fails on a two-cycle offset
    // that has nothing to do with the inversion being tested.
    for (i = 0; i < 8; i = i + 1) begin
      @(posedge clk); #1;
      batch1[i] = sample;
    end
    data_bit <= 0;
    for (i = 0; i < 8; i = i + 1) begin
      @(posedge clk); #1;
      batch2[i] = sample;
    end
    for (i = 0; i < 8; i = i + 1)
      expect("inverted carrier", batch2[i], -batch1[i]);

    $display("4. the code is ternary: only -AMP, 0, +AMP ever appear");
    data_bit <= 1;
    for (i = 0; i < 200; i = i + 1) begin
      @(posedge clk); #1;
      checks = checks + 1;
      if (sample !== 0 && sample !== AMP && sample !== -AMP) begin
        $display("  FAIL sample %0d is not a ternary level", sample);
        errs = errs + 1;
      end
      if (sample != 0) nonzero = nonzero + 1;
    end
    expect("three quarters of samples are non-zero", nonzero, 150);

    $display("5. a frequency word of zero holds the phase still");
    fword <= 0;
    @(posedge clk); @(posedge clk); #1;
    begin : hold
      integer held; held = sample;
      for (i = 0; i < 16; i = i + 1) begin
        @(posedge clk); #1;
        checks = checks + 1;
        if (sample !== held) begin
          $display("  FAIL phase advanced with fword = 0");
          errs = errs + 1;
        end
      end
    end

    $display("");
    $display("checks = %0d", checks);
    $display("failures = %0d", errs);
    if (errs == 0) $display("NCO OK");
    $finish;
  end
  initial begin #400000; $display("TIMEOUT"); $finish; end
endmodule
