`timescale 1ns/1ps
// Two implementations of the same function, checked against each other rather
// than against a model written by the same hand.
//
// tern_corr_pn is combinational over a packed window; tern_corr_pn_tree is a
// pipelined streaming version with a tap RAM. They share no code. Agreement
// over a large random corpus is a much stronger statement than either matching
// a reference the author also wrote -- a misunderstanding of the specification
// reproduces itself in a hand model, but not in an independent implementation.
//
// The corpus is deliberately hostile: full-scale positive and negative samples
// that drive the accumulator to its extremes, alternating patterns, and random
// tap sets including all-positive and all-negative ones.
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

  reg  [N*W-1:0] xwin = 0;
  reg  [N*2-1:0] taps = 0;
  wire signed [ACC-1:0] comb;
  tern_corr_pn #(.N(N),.W(W),.ACC(ACC)) u_comb (
    .xin(xwin), .win(taps), .corr(comb));

  reg signed [W-1:0] hist [0:255];
  integer wr_ptr = 0;
  integer i, k, set, errs, checks, seed;
  reg [1:0] t;
  reg signed [W-1:0] v;
  integer extreme_hits;

  task load_taps(input integer mode);
    begin
      for (i=0;i<N;i=i+1) begin
        case (mode)
          0: t = (((i&1)^((i>>2)&1)^((i>>4)&1)) ? 2'b01 : 2'b10);  // the PN code
          1: t = 2'b01;                                            // all positive
          2: t = 2'b10;                                            // all negative
          3: t = (i[0] ? 2'b01 : 2'b00);                           // half zeroed
          default: begin
               seed = (seed*1103515245 + 12345) & 32'h7FFFFFFF;
               t = (seed[9:8] == 2'b11) ? 2'b00 : seed[9:8];
             end
        endcase
        taps[i*2 +: 2] = t;
        c_addr <= i[AW-1:0]; c_data <= t; c_wr <= 1;
        @(posedge clk); c_wr <= 0; @(posedge clk);
      end
    end
  endtask

  task push(input signed [W-1:0] val);
    begin
      hist[wr_ptr[7:0]] = val; wr_ptr = wr_ptr + 1;
      s_data <= val; s_valid <= 1; @(posedge clk);
      s_valid <= 0; @(posedge clk);          // sparse strobe -> lag 1
    end
  endtask

  initial begin
    errs = 0; checks = 0; seed = 7; extreme_hits = 0;
    for (set = 0; set < 8; set = set + 1) begin
      rst <= 1; wr_ptr = 0; repeat (4) @(posedge clk); rst <= 0; @(posedge clk);
      load_taps(set);
      for (k = 0; k < 400; k = k + 1) begin
        seed = (seed*1103515245 + 12345) & 32'h7FFFFFFF;
        case (seed[17:16])
          2'b00: v =  16'sd2047;
          2'b01: v = -16'sd2047;
          2'b10: v = $signed(seed[15:0]);
          default: v = (k[0] ? 16'sd32767 : -16'sd32768);   // full-scale extremes
        endcase
        if (v == 16'sd32767 || v == -16'sd32768) extreme_hits = extreme_hits + 1;
        push(v);
        if (wr_ptr > N + 1) begin
          // window for the comparison: the tree's output lags by one sample
          for (i = 0; i < N; i = i + 1)
            xwin[i*W +: W] = hist[(wr_ptr - 1 - i) & 8'hFF];
          #1;
          checks = checks + 1;
          if (m_data !== comb) begin
            if (errs < 5)
              $display("  MISMATCH set %0d k %0d: tree %0d, combinational %0d",
                       set, k, m_data, comb);
            errs = errs + 1;
          end
        end
      end
    end
    $display("checks = %0d", checks);
    $display("full-scale samples exercised = %0d", extreme_hits);
    $display("mismatches = %0d", errs);
    if (errs == 0)
      $display("EQUIVALENCE OK: the pipelined and combinational correlators agree");
    $finish;
  end
  initial begin #40000000; $display("TIMEOUT"); $finish; end
endmodule
