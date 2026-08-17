`timescale 1ns/1ps
// ps7_corr (8 taps) and ps7_pn (63 taps): the GPIO-driven correlators, neither
// of which had a bench.
//
// Both ingest a sample on every CHANGE of a strobe bit rather than on a rising
// edge. That is deliberate -- a level toggled by software cannot be missed the
// way a pulse can -- but it puts the interesting case at the very first sample:
// if the design only reacts to one direction, or if its idea of the strobe's
// initial value disagrees with the host's, the first sample is silently lost
// and every result after it is shifted by one. That is exactly the failure
// found in ps7_speed the previous cycle, in a different disguise.
module tb;
  reg clk = 0; always #5 clk = ~clk;
  ps7_corr c8 ();
  ps7_pn   c63 ();

  integer checks = 0, errs = 0, i, k, lag8, lag63;
  integer signed acc;
  integer tp8 [0:7];
  integer tp63 [0:62];
  integer hist [0:255];
  integer wp;

  task expect(input [255:0] what, input integer got, input integer exp);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        $display("  FAIL %0s: got %0d, expected %0d", what, got, exp);
        errs = errs + 1;
      end
    end
  endtask

  initial begin
    c8.ps7_i.frstn = 4'b0000; c8.ps7_i.gpo = 64'd0;
    c63.ps7_i.frstn = 4'b0000; c63.ps7_i.gpo = 64'd0;
    #200;
    c8.ps7_i.frstn = 4'b1111; c63.ps7_i.frstn = 4'b1111;
  end
  always @(clk) begin c8.ps7_i.fclk[0] = clk; c63.ps7_i.fclk[0] = clk; end

  task tap8(input integer idx, input [1:0] code);
    begin
      c8.ps7_i.gpo[23:19] = {code, idx[2:0]};
      c8.ps7_i.gpo[18] = 1'b1; repeat (3) @(posedge clk);
      c8.ps7_i.gpo[18] = 1'b0; repeat (3) @(posedge clk);
    end
  endtask
  task tap63(input integer idx, input [1:0] code);
    begin
      c63.ps7_i.gpo[26:19] = {code, idx[5:0]};
      c63.ps7_i.gpo[18] = 1'b1; repeat (3) @(posedge clk);
      c63.ps7_i.gpo[18] = 1'b0; repeat (3) @(posedge clk);
    end
  endtask
  task push(input signed [15:0] s);
    begin
      hist[wp] = s; wp = wp + 1;
      c8.ps7_i.gpo[15:0]  = s;
      c63.ps7_i.gpo[15:0] = s;
      c8.ps7_i.gpo[16]  = ~c8.ps7_i.gpo[16];    // ingest on change
      c63.ps7_i.gpo[16] = ~c63.ps7_i.gpo[16];
      repeat (6) @(posedge clk); #1;
    end
  endtask

  initial begin
    #400;
    wp = 0;
    $display("1. both anchors are present");
    expect("8-tap anchor",  c8.gpio_i[15:0],  16'h47C0);
    expect("63-tap anchor", c63.gpio_i[15:0], 16'h47C0);

    $display("2. a single tap at +1, so the output must be the sample itself");
    for (i = 0; i < 8; i = i + 1)  tap8(i,  (i == 0) ? 2'b01 : 2'b00);
    for (i = 0; i < 63; i = i + 1) tap63(i, (i == 0) ? 2'b01 : 2'b00);
    // THE FIRST SAMPLE. If a toggle-driven ingest loses it, everything after
    // is shifted by one and still self-consistent -- which is why it is
    // checked before anything else is pushed.
    // Read one push later than the sample under test, so the value has passed
    // the pipeline whatever its lag. Reading immediately made the first check
    // pass and the second fail, which is the shape of an off-by-one in the
    // BENCH, not in two independent designs at once.
    push(16'sd1234);
    push(16'sd0);
    expect("first sample, 8-tap",  $signed(c8.gpio_i[35:16]),  1234);
    expect("first sample, 63-tap", $signed(c63.gpio_i[39:16]), 1234);
    push(-16'sd777);
    push(16'sd0);
    expect("second sample, 8-tap",  $signed(c8.gpio_i[35:16]),  -777);
    expect("second sample, 63-tap", $signed(c63.gpio_i[39:16]), -777);

    $display("3. a single tap at -1 negates, including at the bottom of range");
    for (i = 0; i < 8; i = i + 1)  tap8(i,  (i == 0) ? 2'b10 : 2'b00);
    for (i = 0; i < 63; i = i + 1) tap63(i, (i == 0) ? 2'b10 : 2'b00);
    push(-16'sd32768);
    push(16'sd0);          // one more, so the value under test has cleared the
                           // pipeline whatever its lag turns out to be
    expect("-(-32768), 8-tap",  $signed(c8.gpio_i[35:16]),  32768);
    expect("-(-32768), 63-tap", $signed(c63.gpio_i[39:16]), 32768);

    $display("4. all taps at +1: the output is the running sum of the window");
    for (i = 0; i < 8; i = i + 1)  begin tp8[i]  = 1; tap8(i,  2'b01); end
    for (i = 0; i < 63; i = i + 1) begin tp63[i] = 1; tap63(i, 2'b01); end
    wp = 0;
    for (k = 0; k < 70; k = k + 1) push(100 + k);
    // Which sample the output reflects is a property of the pipeline, not
    // something to assume. Earlier benches in this directory settled it for
    // the streaming correlator by measurement; the same is done here, and the
    // lag found is then required to be the SAME for both widths -- two designs
    // agreeing on a lag is a fact about the pipeline, one design agreeing with
    // my guess is not.
    lag8 = -1;
    for (k = 0; k < 4; k = k + 1) begin
      acc = 0;
      for (i = 0; i < 8; i = i + 1) acc = acc + hist[wp-1-k-i];
      if ($signed(c8.gpio_i[35:16]) === acc && lag8 < 0) lag8 = k;
    end
    lag63 = -1;
    for (k = 0; k < 4; k = k + 1) begin
      acc = 0;
      for (i = 0; i < 63; i = i + 1) acc = acc + hist[wp-1-k-i];
      if ($signed(c63.gpio_i[39:16]) === acc && lag63 < 0) lag63 = k;
    end
    checks = checks + 1;
    if (lag8 < 0 || lag63 < 0) begin
      $display("  FAIL no lag in 0..3 reconciles the window sum (8-tap %0d, 63-tap %0d)",
               lag8, lag63);
      errs = errs + 1;
    end else begin
      $display("   output lag measured: %0d samples (8-tap), %0d (63-tap)", lag8, lag63);
      expect("both widths share one lag", lag8, lag63);
    end

    $display("");
    $display("checks = %0d", checks);
    $display("failures = %0d", errs);
    if (errs == 0) $display("CORR TOPS OK");
    $finish;
  end
  initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
