`timescale 1ns/1ps
// Inject one x vector into the K x N systolic array, dump y each cycle to find
// the diagonal-wavefront latency, and check against the reference y = x . W.
module tern_systolic_tb;
  localparam K=4,N=4,W=8,ACC=24;
  localparam [1:0] P=2'b01,M=2'b10,Z=2'b00;
  reg clk=0,rst=1,w_load=0,x_valid=0; reg [K*N*2-1:0] w_all; reg [K*W-1:0] x_vec;
  wire [N*ACC-1:0] y_col;
  tern_systolic #(.K(K),.N(N),.W(W),.ACC(ACC)) dut(.clk(clk),.rst(rst),
    .w_load(w_load),.w_all(w_all),.x_valid(x_valid),.x_vec(x_vec),.y_col(y_col));
  always #5 clk=~clk;

  reg [1:0] wm [0:K*N-1];           // flat W[k*N+n]
  reg signed [W-1:0] xv [0:K-1];
  integer k,n,c,dc; integer yr [0:N-1];
  initial begin
    wm[0]=P; wm[1]=M; wm[2]=Z; wm[3]=P;   // row 0
    wm[4]=P; wm[5]=P; wm[6]=M; wm[7]=Z;   // row 1
    wm[8]=M; wm[9]=Z; wm[10]=P;wm[11]=P;  // row 2
    wm[12]=Z;wm[13]=P;wm[14]=P;wm[15]=M;  // row 3
    xv[0]=20; xv[1]=-13; xv[2]=41; xv[3]=7;
    for(n=0;n<N;n=n+1) begin yr[n]=0;
      for(k=0;k<K;k=k+1) begin
        dc = (wm[k*N+n]==P)?1:(wm[k*N+n]==M)?-1:0; yr[n]=yr[n]+xv[k]*dc; end
    end
    $display("reference y = %0d %0d %0d %0d", yr[0],yr[1],yr[2],yr[3]);
    for(k=0;k<K*N;k=k+1) w_all[k*2 +: 2]=wm[k];
    for(k=0;k<K;k=k+1) x_vec[k*W +: W]=xv[k];
    @(negedge clk); rst=0; @(negedge clk); w_load=1; @(negedge clk); w_load=0;
    @(negedge clk); x_valid=1; @(negedge clk); x_valid=0;
    for(c=0;c<12;c=c+1) begin
      @(posedge clk); #1;
      $write("t+%0d: ",c);
      for(n=0;n<N;n=n+1) $write("%0d ", $signed(y_col[n*ACC +: ACC]));
      $write("\n");
    end
    $finish;
  end
endmodule
