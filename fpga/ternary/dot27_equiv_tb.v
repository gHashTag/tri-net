`timescale 1ns/1ps
// A second, independent check on tern_dot27.
//
// The coverage matrix showed a broken adder tree in tern_dot27 being caught by
// exactly one bench. One bench is a single point of failure: delete it, or
// weaken its checker as happened to pn_despread, and that whole fault class
// goes invisible.
//
// This drives the same module from a different angle -- a flat behavioural sum
// rather than a matrix-of-neurons reference -- over a large random corpus plus
// the boundary cases that random data reaches only by accident.
module tb;
  localparam K=27, W=8, ACC=16;
  reg  [K*W-1:0] act = 0;
  reg  [K*2-1:0] wts = 0;
  wire signed [ACC-1:0] dot;
  tern_dot27 #(.K(K),.W(W),.ACC(ACC)) u (.act(act),.wts(wts),.dot(dot));

  integer i, n, errs, checks, seed, extremes;
  integer signed ref_;
  reg signed [W-1:0] a;
  reg [1:0] t;

  task model;
    begin
      ref_ = 0;
      for (i=0;i<K;i=i+1) begin
        a = act[i*W +: W];
        t = wts[i*2 +: 2];
        if (t == 2'b01) ref_ = ref_ + $signed(a);
        else if (t == 2'b10) ref_ = ref_ - $signed(a);
      end
    end
  endtask
  task expect(input [255:0] what);
    begin
      model; #1;
      checks = checks + 1;
      if (dot !== ref_[ACC-1:0]) begin
        if (errs < 5)
          $display("  MISMATCH %0s: dut %0d, model %0d", what, dot, ref_);
        errs = errs + 1;
      end
    end
  endtask

  initial begin
    errs = 0; checks = 0; seed = 31; extremes = 0;

    $display("1. random activations and weights");
    for (n = 0; n < 800; n = n + 1) begin
      for (i=0;i<K;i=i+1) begin
        seed = (seed*1103515245 + 12345) & 32'h7FFFFFFF;
        act[i*W +: W] = seed[15:8];
        wts[i*2 +: 2] = (seed[5:4] == 2'b11) ? 2'b00 : seed[5:4];
      end
      expect("random");
    end

    $display("2. every weight positive, every activation at the bottom of range");
    for (i=0;i<K;i=i+1) begin act[i*W +: W] = -8'sd128; wts[i*2 +: 2] = 2'b01; end
    extremes = extremes + 1; expect("27 x -128");

    $display("3. every weight negative, every activation at the bottom of range");
    $display("   (-128 has no positive counterpart at 8 bits)");
    for (i=0;i<K;i=i+1) begin act[i*W +: W] = -8'sd128; wts[i*2 +: 2] = 2'b10; end
    extremes = extremes + 1; expect("-(27 x -128)");

    $display("4. every weight positive, every activation at the top of range");
    for (i=0;i<K;i=i+1) begin act[i*W +: W] = 8'sd127; wts[i*2 +: 2] = 2'b01; end
    extremes = extremes + 1; expect("27 x 127");

    $display("5. all weights zero");
    for (i=0;i<K;i=i+1) begin act[i*W +: W] = -8'sd128; wts[i*2 +: 2] = 2'b00; end
    expect("zero weights");
    #1; checks = checks + 1;
    if (dot !== 0) begin $display("  MISMATCH zero weights: dut %0d, want 0", dot); errs = errs + 1; end

    $display("6. one weight at a time, swept across all 27 positions");
    for (n = 0; n < K; n = n + 1) begin
      for (i=0;i<K;i=i+1) begin
        act[i*W +: W] = i[W-1:0] + 8'sd1;
        wts[i*2 +: 2] = (i==n) ? 2'b01 : 2'b00;
      end
      expect("single positive weight");
      wts[n*2 +: 2] = 2'b10;
      expect("single negative weight");
    end

    $display("");
    $display("checks = %0d", checks);
    $display("boundary cases = %0d", extremes);
    $display("mismatches = %0d", errs);
    if (errs == 0) $display("DOT27 EQUIVALENCE OK");
    $finish;
  end
  initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
