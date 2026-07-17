`timescale 1ns/1ps
module tern_softmax_tb;
  localparam N=8,LOGW=12,PW=17;
  reg signed [N*LOGW-1:0] x; wire [N*PW-1:0] prob;
  tern_softmax #(.N(N),.LOGW(LOGW),.PW(PW)) dut(.x(x),.prob(prob));
  integer i; reg signed [LOGW-1:0] xv [0:N-1];
  initial begin
    // Q2 logits (real value = x/4): a spread set
    xv[0]=12; xv[1]=-8; xv[2]=20; xv[3]=4; xv[4]=-20; xv[5]=16; xv[6]=0; xv[7]=8;
    for(i=0;i<N;i=i+1) x[i*LOGW +: LOGW]=xv[i];
    #1;
    for(i=0;i<N;i=i+1) $display("p[%0d]=%0d", i, prob[i*PW +: PW]);
    $finish;
  end
endmodule
