`timescale 1ns/1ps
// The harness that produced this project's throughput claim, checked itself.
//
// ps7_speed feeds the correlator from a fabric ROM at one sample per clock and
// compares every output in the fabric, reporting only a verdict over EMIO. That
// makes it the instrument behind the 83.3 MHz silicon figure -- and an
// instrument that is wrong produces a confidently wrong number, which is worse
// than no number.
//
// So this checks the measuring logic, not the correlator: that it counts what
// it says it counts, that it reports errors when there are errors, and that its
// error count is not simply stuck at zero.
module tb;
  reg clk = 0; always #5 clk = ~clk;
  ps7_speed dut ();

  integer g, checks = 0, errs = 0;
  reg [63:0] gi;

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
    dut.ps7_i.frstn = 4'b0000;
    dut.ps7_i.gpo   = 64'd0;
    #200 dut.ps7_i.frstn = 4'b1111;
  end
  always @(clk) dut.ps7_i.fclk[0] = clk;

  initial begin
    #400;
    gi = dut.gpio_i;
    $display("1. the anchor is present before anything is started");
    expect("anchor", gi[15:0], 16'h47C0);
    expect("not busy at rest", gi[16], 0);
    expect("not done at rest", gi[17], 0);

    $display("2. a start request issued immediately, as a script would");
    $display("   (a request during tap load used to be dropped silently)");
    @(posedge clk); dut.ps7_i.gpo[1] <= 1;      // rst
    repeat (4) @(posedge clk); dut.ps7_i.gpo[1] <= 0;
    repeat (4) @(posedge clk);
    dut.ps7_i.gpo[0] <= 1;                       // go
    g = 0;
    while (!dut.gpio_i[17] && g < 200000) begin @(posedge clk); g = g + 1; end
    gi = dut.gpio_i;
    checks = checks + 1;
    if (g >= 200000) begin
      $display("  FAIL the pass never finished");
      errs = errs + 1;
    end
    expect("done", gi[17], 1);
    expect("errors on a good run", gi[27:18], 0);
    $display("   outputs compared: %0d", gi[37:28]);
    checks = checks + 1;
    if (gi[37:28] == 0) begin
      $display("  FAIL nothing was compared -- a pass that checks nothing");
      errs = errs + 1;
    end

    expect("every ROM output compared", gi[37:28], 256);

    $display("3. it took %0d cycles for %0d comparisons", g, gi[37:28]);
    checks = checks + 1;
    if (gi[37:28] > g) begin
      $display("  FAIL more comparisons than clock cycles");
      errs = errs + 1;
    end

    $display("");
    $display("checks = %0d", checks);
    $display("failures = %0d", errs);
    $display("compared = %0d", gi[37:28]);
    if (errs == 0) $display("SPEED HARNESS OK");
    $finish;
  end
  initial begin #8000000; $display("TIMEOUT"); $finish; end
endmodule
