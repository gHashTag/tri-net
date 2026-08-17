`timescale 1ns/1ps
// The rate sweep found two points where no constant lag reconciles the captured
// output with the model. A constant lag exists only if the valid strobe has a
// constant duty: m_data is registered every clock while corr advances only on
// s_valid, so a strobe that is sometimes sparse and sometimes back-to-back puts
// the capture a different distance behind on different samples.
//
// This asks whether that alone reproduces the failure, with no clock domains and
// no vendor logic involved.
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

  reg [W-1:0]   in_mem  [0:127];
  reg [ACC-1:0] out_mem [0:127];
  reg [7:0] idx=0; reg capturing=0;
  always @(posedge clk) if (capturing && s_valid && !idx[7]) begin
    in_mem[idx[6:0]] <= s_data; out_mem[idx[6:0]] <= m_data;
    idx <= idx + 1'b1;
  end

  integer tp [0:N-1];
  integer i,j,k,errs,expect_,seed,gap,mode,best,bestlag;

  task push(input integer g);
    integer q;
    begin
      seed = (seed*1103515245 + 12345) & 32'h7FFFFFFF;
      s_data <= seed[15:0]; s_valid<=1; @(posedge clk); s_valid<=0;
      for (q=0;q<g;q=q+1) @(posedge clk);
    end
  endtask

  initial begin
    for (i=0;i<N;i=i+1) tp[i] = ((i&1)^((i>>2)&1)^((i>>4)&1)) ? 1 : -1;
    for (mode=0; mode<3; mode=mode+1) begin
      rst<=1; idx<=0; capturing<=0; repeat(4) @(posedge clk); rst<=0; @(posedge clk);
      for (i=0;i<N;i=i+1) begin
        c_addr<=i[AW-1:0];
        c_data<= (((i&1)^((i>>2)&1)^((i>>4)&1)) ? 2'b01 : 2'b10);
        c_wr<=1; @(posedge clk); c_wr<=0; @(posedge clk);
      end
      seed = 12345;
      for (k=0;k<64;k=k+1) push(mode==0 ? 1 : (mode==1 ? 0 : (k[0] ? 0 : 1)));
      capturing<=1;
      for (k=0;k<130;k=k+1) push(mode==0 ? 1 : (mode==1 ? 0 : (k[0] ? 0 : 1)));
      capturing<=0; @(posedge clk);
      best = 9999; bestlag = -1;
      for (j=0;j<4;j=j+1) begin
        errs = 0;
        for (k=j+N; k<128; k=k+1) begin
          expect_ = 0;
          for (i=0;i<N;i=i+1) expect_ = expect_ + tp[i]*$signed(in_mem[k-j-i]);
          if ($signed(out_mem[k]) !== $signed(expect_[ACC-1:0])) errs = errs + 1;
        end
        if (errs < best) begin best = errs; bestlag = j; end
      end
      case (mode)
        0: $display("sparse strobe   (one valid, one gap) : best lag %0d, %0d mismatches", bestlag, best);
        1: $display("back-to-back    (valid every cycle)  : best lag %0d, %0d mismatches", bestlag, best);
        2: $display("MIXED duty      (alternating)        : best lag %0d, %0d mismatches", bestlag, best);
      endcase
    end
    $finish;
  end
  initial begin #900000; $display("TIMEOUT"); $finish; end
endmodule
