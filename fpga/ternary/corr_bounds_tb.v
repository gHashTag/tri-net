`timescale 1ns/1ps
// Directed boundary coverage. Random vectors explore the middle of the space
// well and its edges by accident; these cases are chosen because they are the
// ones where an implementation can be wrong in a way that ordinary data hides.
//
// The sharpest is the negation asymmetry. In two's complement -32768 has no
// positive counterpart in 16 bits: negating it at W width gives -32768 again.
// A correlator tap of -1 must therefore sign-extend to the accumulator width
// FIRST and negate SECOND. An implementation that does it the other way passes
// every test whose samples avoid the one value at the bottom of the range.
module tb;
  localparam N=63, W=16, ACC=24, AW=6;

  reg clk=0; always #5 clk=~clk;
  reg rst=1, s_valid=0;
  reg signed [W-1:0] s_data=0;
  reg c_wr=0; reg [AW-1:0] c_addr=0; reg [1:0] c_data=0;
  wire m_valid; wire signed [ACC-1:0] m_data;
  tern_corr_pn_tree #(.N(N),.W(W),.ACC(ACC),.AW(AW)) u_tree (
    .clk(clk),.rst(rst),.s_valid(s_valid),.s_data(s_data),
    .c_wr(c_wr),.c_addr(c_addr),.c_data(c_data),
    .m_valid(m_valid),.m_data(m_data));

  reg [N*W-1:0] xwin = 0;
  reg [N*2-1:0] taps = 0;
  wire signed [ACC-1:0] comb;
  tern_corr_pn #(.N(N),.W(W),.ACC(ACC)) u_comb (.xin(xwin),.win(taps),.corr(comb));

  integer i, p, errs, checks;
  integer signed want;
  reg signed [W-1:0] hist [0:127];
  integer wr;

  task set_taps(input [1:0] code);
    begin
      for (i=0;i<N;i=i+1) begin
        taps[i*2 +: 2] = code;
        c_addr <= i[AW-1:0]; c_data <= code; c_wr <= 1;
        @(posedge clk); c_wr <= 0; @(posedge clk);
      end
    end
  endtask
  task one_tap(input integer pos, input [1:0] code);
    begin
      for (i=0;i<N;i=i+1) begin
        taps[i*2 +: 2] = (i==pos) ? code : 2'b00;
        c_addr <= i[AW-1:0]; c_data <= (i==pos) ? code : 2'b00; c_wr <= 1;
        @(posedge clk); c_wr <= 0; @(posedge clk);
      end
    end
  endtask
  task fill(input signed [W-1:0] v);
    begin
      rst <= 1; wr = 0; repeat (3) @(posedge clk); rst <= 0; @(posedge clk);
      for (i=0;i<N+2;i=i+1) begin
        hist[wr[6:0]] = v; wr = wr + 1;
        s_data <= v; s_valid <= 1; @(posedge clk); s_valid <= 0; @(posedge clk);
      end
      for (i=0;i<N;i=i+1) xwin[i*W +: W] = hist[(wr-1-i) & 7'h7F];
      #1;
    end
  endtask
  task ramp;
    begin
      rst <= 1; wr = 0; repeat (3) @(posedge clk); rst <= 0; @(posedge clk);
      for (i=0;i<N+2;i=i+1) begin
        hist[wr[6:0]] = i[W-1:0] + 16'sd100; wr = wr + 1;
        s_data <= i[W-1:0] + 16'sd100; s_valid <= 1;
        @(posedge clk); s_valid <= 0; @(posedge clk);
      end
      for (i=0;i<N;i=i+1) xwin[i*W +: W] = hist[(wr-1-i) & 7'h7F];
      #1;
    end
  endtask
  task check(input [255:0] label, input integer expect_);
    begin
      checks = checks + 1;
      if (comb !== expect_) begin
        $display("  FAIL %0s: combinational %0d, expected %0d", label, comb, expect_);
        errs = errs + 1;
      end
      if (m_data !== expect_) begin
        $display("  FAIL %0s: tree %0d, expected %0d", label, m_data, expect_);
        errs = errs + 1;
      end
    end
  endtask

  initial begin
    errs = 0; checks = 0;

    $display("A. all taps zero -- the output must be exactly zero");
    set_taps(2'b00); fill(16'sd12345); check("zero taps", 0);
    set_taps(2'b00); fill(-16'sd32768); check("zero taps, extreme data", 0);

    $display("B. one tap at +1, swept across all 63 positions");
    ramp;
    for (p = 0; p < N; p = p + 1) begin
      one_tap(p, 2'b01);
      #1;
      want = $signed(hist[(wr-1-p) & 7'h7F]);
      check("single +1 tap", want);
    end

    $display("C. one tap at -1, swept across all 63 positions");
    for (p = 0; p < N; p = p + 1) begin
      one_tap(p, 2'b10);
      #1;
      want = -$signed(hist[(wr-1-p) & 7'h7F]);
      check("single -1 tap", want);
    end

    $display("D. all taps +1 with every sample at the bottom of the range");
    set_taps(2'b01); fill(-16'sd32768);
    check("63 x -32768", -63*32768);

    $display("E. all taps -1 with every sample at the bottom of the range");
    $display("   (this is the case where negating before sign-extending fails)");
    set_taps(2'b10); fill(-16'sd32768);
    check("-(63 x -32768)", 63*32768);

    $display("F. all taps +1 with every sample at the top of the range");
    set_taps(2'b01); fill(16'sd32767);
    check("63 x 32767", 63*32767);

    $display("");
    $display("worst-case magnitude reachable = %0d", 63*32768);
    $display("accumulator range at ACC=%0d is +/- %0d", ACC, 1<<(ACC-1));
    if (63*32768 >= (1<<(ACC-1)))
      $display("  WARNING: the accumulator can overflow at these parameters");
    else
      $display("  the accumulator cannot overflow at these parameters");
    $display("checks = %0d", checks);
    $display("failures = %0d", errs);
    if (errs == 0) $display("BOUNDS OK");
    $finish;
  end
  initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
