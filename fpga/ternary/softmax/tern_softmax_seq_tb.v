`timescale 1ns/1ps
module tern_softmax_seq_tb;
  localparam N=8,LOGW=12,PW=17;
  reg clk=0,rst=1,start=0; reg signed [N*LOGW-1:0] x; wire done; wire [N*PW-1:0] prob;
  tern_softmax_seq #(.N(N),.LOGW(LOGW),.PW(PW)) dut(.clk(clk),.rst(rst),.start(start),.x(x),.done(done),.prob(prob));
  always #5 clk=~clk;
  integer i; reg signed [LOGW-1:0] xv [0:N-1];
  initial begin
    xv[0]=12; xv[1]=-8; xv[2]=20; xv[3]=4; xv[4]=-20; xv[5]=16; xv[6]=0; xv[7]=8;
    for(i=0;i<N;i=i+1) x[i*LOGW +: LOGW]=xv[i];
    @(negedge clk); rst=0; @(negedge clk); start=1; @(negedge clk); start=0;
    wait(done); @(negedge clk);
    for(i=0;i<N;i=i+1) $display("p[%0d]=%0d", i, prob[i*PW +: PW]);
    $finish;
  end
endmodule
