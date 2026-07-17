`timescale 1ns/1ps
module tern_matvec_tiled_tb;
  localparam M=32,K=27,MT=4,W=8,ACC=16;
  reg clk=0,rst=1,start=0; reg [K*W-1:0] x; reg [M*K*2-1:0] w_all;
  wire done; wire [M*ACC-1:0] y;
  tern_matvec_tiled #(.M(M),.K(K),.MT(MT),.W(W),.ACC(ACC)) dut(.clk(clk),.rst(rst),
    .start(start),.x(x),.w_all(w_all),.done(done),.y(y));
  always #5 clk=~clk;
  reg [1:0] wc [0:M*K-1]; reg signed [W-1:0] xv [0:K-1];
  integer m,k,c; integer refy [0:M-1]; integer dec, hw;
  initial begin
    // deterministic ternary weights + int8 x
    for(m=0;m<M;m=m+1) for(k=0;k<K;k=k+1) wc[m*K+k]=(($random%3)+3)%3;  // 0,1,2
    for(k=0;k<K;k=k+1) xv[k]=($random%201)-100;
    for(m=0;m<M*K;m=m+1) w_all[m*2+:2]=wc[m];
    for(k=0;k<K;k=k+1) x[k*W+:W]=xv[k];
    // reference: y[m] = sum_k decode(wc[m][k]) * x[k]
    for(m=0;m<M;m=m+1) begin refy[m]=0;
      for(k=0;k<K;k=k+1) begin dec=(wc[m*K+k]==1)?1:(wc[m*K+k]==2)?-1:0; refy[m]=refy[m]+dec*xv[k]; end end
    @(negedge clk); rst=0; @(negedge clk); start=1; @(negedge clk); start=0;
    c=0; while(!done && c<100) begin @(negedge clk); c=c+1; end
    @(negedge clk);
    hw=0;
    for(m=0;m<M;m=m+1) if($signed(y[m*ACC+:ACC])!==refy[m]) hw=hw+1;
    $display("tiled matvec M=%0d MT=%0d (%0d tiles): %0d mismatches, latency %0d cycles", M, MT, (M+MT-1)/MT, hw, c);
    if(hw==0) $display("TILED MATVEC: bit-exact vs full -- big layer runs on small engine"); else $display("MISMATCH");
    $finish;
  end
endmodule
