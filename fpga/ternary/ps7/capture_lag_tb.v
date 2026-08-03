`timescale 1ns/1ps
// Does the single-index capture really put the output two samples behind the
// input? The rate sweep showed that a two-counter capture leaves the relation
// to the phase at capture start, which is exactly what a testbench can settle
// before a board run is spent on it.
module tb;
  localparam N=63, W=16, ACC=24, AW=6;
  reg clk=0; always #5 clk=~clk;
  reg rst=1;
  reg s_valid=0; reg [W-1:0] s_data=0;
  reg c_wr=0; reg [AW-1:0] c_addr=0; reg [1:0] c_data=0;
  wire m_valid; wire signed [ACC-1:0] m_data;

  tern_corr_pn_tree #(.N(N),.W(W),.ACC(ACC),.AW(AW)) u (
    .clk(clk),.rst(rst),.s_valid(s_valid),.s_data(s_data),
    .c_wr(c_wr),.c_addr(c_addr),.c_data(c_data),
    .m_valid(m_valid),.m_data(m_data));

  // single-index capture, exactly as the RTL does it
  reg [W-1:0]   in_mem  [0:127];
  reg [ACC-1:0] out_mem [0:127];
  reg [7:0] idx=0; reg capturing=0;
  always @(posedge clk) if (capturing && s_valid && !idx[7]) begin
    in_mem[idx[6:0]]  <= s_data;
    out_mem[idx[6:0]] <= m_data;
    idx <= idx + 1'b1;
  end

  integer tp [0:N-1];
  integer i, j, k, errs, expect_, seed;
  reg signed [W-1:0] hist [0:255];

  initial begin
    for (i=0;i<N;i=i+1) tp[i] = ((i&1)^((i>>2)&1)^((i>>4)&1)) ? 1 : -1;
    repeat (4) @(posedge clk); rst<=0; @(posedge clk);
    for (i=0;i<N;i=i+1) begin
      c_addr<=i[AW-1:0];
      c_data<= (((i&1)^((i>>2)&1)^((i>>4)&1)) ? 2'b01 : 2'b10);
      c_wr<=1; @(posedge clk); c_wr<=0; @(posedge clk);
    end
    // warm the shift register, then capture
    seed = 12345;
    for (k=0;k<64;k=k+1) begin
      seed = (seed*1103515245 + 12345) & 32'h7FFFFFFF;
      s_data <= seed[15:0]; hist[k] <= seed[15:0];
      s_valid<=1; @(posedge clk); s_valid<=0; @(posedge clk);
    end
    capturing <= 1;
    for (k=64;k<192;k=k+1) begin
      seed = (seed*1103515245 + 12345) & 32'h7FFFFFFF;
      s_data <= seed[15:0]; hist[k] <= seed[15:0];
      s_valid<=1; @(posedge clk); s_valid<=0; @(posedge clk);
    end
    capturing <= 0; @(posedge clk);

    for (j=0;j<4;j=j+1) begin
      errs = 0;
      for (k=j+N; k<128; k=k+1) begin
        expect_ = 0;
        for (i=0;i<N;i=i+1) expect_ = expect_ + tp[i]*$signed(in_mem[k-j-i]);
        if ($signed(out_mem[k]) !== $signed(expect_[ACC-1:0])) errs = errs + 1;
      end
      $display("lag %0d : %0d mismatches of %0d", j, errs, 128-(j+N));
    end
    $finish;
  end
  initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
