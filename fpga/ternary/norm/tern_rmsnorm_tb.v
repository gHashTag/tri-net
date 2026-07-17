`timescale 1ns/1ps
module tern_rmsnorm_tb;
  localparam N=8,W=8,OUTQ=6;
  reg signed [N*W-1:0] x; wire signed [N*(W+OUTQ)-1:0] y;
  tern_rmsnorm #(.N(N),.W(W),.OUTQ(OUTQ),.LOG2N(3)) dut(.x(x),.y(y));
  reg signed [W-1:0] xv[0:N-1]; integer i;
  initial begin
    xv[0]=40;xv[1]=-70;xv[2]=15;xv[3]=90;xv[4]=-30;xv[5]=55;xv[6]=-12;xv[7]=25;
    for(i=0;i<N;i=i+1) x[i*W+:W]=xv[i]; #1;
    for(i=0;i<N;i=i+1) $display("y[%0d]=%0d",i,$signed(y[i*(W+OUTQ)+:(W+OUTQ)])); $finish;
  end
endmodule
