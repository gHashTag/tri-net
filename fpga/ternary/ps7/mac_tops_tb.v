`timescale 1ns/1ps
// ps7_tern and ps7_probe: the two smallest board designs, a sign-select
// multiply-accumulate driven entirely over EMIO. Neither had a bench.
//
// The case worth aiming at is x = -128. A ternary weight of -1 must negate
// after widening, not before: at 8 bits -(-128) is -128 again, so an
// implementation that negates in place returns the input unchanged and looks
// correct for every other value.
module tb;
  reg clk = 0; always #5 clk = ~clk;
  ps7_tern  a ();
  ps7_probe b ();

  integer checks = 0, errs = 0, i, hb0, hb1;
  reg signed [8:0] want;

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
    a.ps7_i.frstn = 4'b0000; a.ps7_i.gpo = 64'd0;
    b.ps7_i.frstn = 4'b0000; b.ps7_i.gpo = 64'd0;
    #200;
    a.ps7_i.frstn = 4'b1111; b.ps7_i.frstn = 4'b1111;
  end
  always @(clk) begin a.ps7_i.fclk[0] = clk; b.ps7_i.fclk[0] = clk; end

  task drive(input signed [7:0] x, input [1:0] w);
    begin
      a.ps7_i.gpo[9:0] = {w, x};
      b.ps7_i.gpo[9:0] = {w, x};
      repeat (4) @(posedge clk); #1;
    end
  endtask

  initial begin
    #400;
    $display("1. both designs answer with their anchor");
    expect("probe anchor", b.gpio_i[15:0], 16'h47C0);

    $display("2. the three weight codes, over the full sample range");
    for (i = -128; i < 128; i = i + 1) begin
      drive(i[7:0], 2'b01);
      expect("weight +1", $signed(a.gpio_i[8:0]), i);
      expect("weight +1 (probe)", $signed(b.gpio_i[24:16]), i);
      drive(i[7:0], 2'b10);
      expect("weight -1", $signed(a.gpio_i[8:0]), -i);
      expect("weight -1 (probe)", $signed(b.gpio_i[24:16]), -i);
      drive(i[7:0], 2'b00);
      expect("weight 0", $signed(a.gpio_i[8:0]), 0);
    end

    $display("3. the bottom of the range, stated separately because it is the");
    $display("   one value where negating before widening returns the input");
    drive(-8'sd128, 2'b10);
    expect("-(-128) must be +128", $signed(a.gpio_i[8:0]), 128);

    $display("4. the heartbeat counter runs, and the right bits are exposed");
    // The exposed field is cnt[30:24], so its lowest bit turns over every
    // 16.7 million cycles -- a third of a second on the board, and far beyond
    // any simulation worth running. Waiting for it to move is the wrong test.
    // What can be checked here is that the counter advances at all, and that
    // the field is wired to the bits the header claims.
    hb0 = b.cnt;
    repeat (400) @(posedge clk); #1;
    hb1 = b.cnt;
    checks = checks + 1;
    if (hb1 - hb0 !== 400) begin
      $display("  FAIL counter advanced %0d in 400 cycles", hb1 - hb0);
      errs = errs + 1;
    end
    for (i = 0; i < 8; i = i + 1) begin
      repeat (37) @(posedge clk); #1;
      expect("exposed field is cnt[30:24]", b.gpio_i[31:25], b.cnt[30:24]);
    end

    $display("");
    $display("checks = %0d", checks);
    $display("failures = %0d", errs);
    if (errs == 0) $display("MAC TOPS OK");
    $finish;
  end
  initial begin #4000000; $display("TIMEOUT"); $finish; end
endmodule
