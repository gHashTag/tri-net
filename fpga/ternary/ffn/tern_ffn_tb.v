`timescale 1ns/1ps
module tern_ffn_tb;
  localparam D=4,H=8,W=8,ACC=24,S1=3,S2=3;
  reg clk=0,rst=1,start=0; reg [D*W-1:0] x; reg [H*D*2-1:0] w1; reg [D*H*2-1:0] w2;
  wire done; wire [D*ACC-1:0] y_flat; wire [7:0] cycles;
  tern_ffn #(.D(D),.H(H),.W(W),.ACC(ACC),.S1(S1),.S2(S2)) dut(.clk(clk),.rst(rst),
    .start(start),.x(x),.w1(w1),.w2(w2),.done(done),.y_flat(y_flat),.cycles(cycles));
  always #5 clk=~clk;
  reg [1:0] w1c [0:H*D-1], w2c [0:D*H-1]; reg signed [W-1:0] xv [0:D-1];
  integer i;
  initial begin
    $readmemh("ffn_W1.hex",w1c); $readmemh("ffn_W2.hex",w2c); $readmemh("ffn_x.hex",xv);
    for(i=0;i<H*D;i=i+1) w1[i*2+:2]=w1c[i];
    for(i=0;i<D*H;i=i+1) w2[i*2+:2]=w2c[i];
    for(i=0;i<D;i=i+1) x[i*W+:W]=xv[i];
    @(negedge clk); rst=0; @(negedge clk); start=1; @(negedge clk); start=0;
    wait(done); @(negedge clk);
    $display("cycles=%0d", cycles);
    for(i=0;i<D;i=i+1) $display("y[%0d]=%0d", i, $signed(y_flat[i*ACC +: ACC]));
    $finish;
  end
  initial #200000 begin $display("TIMEOUT"); $finish; end
endmodule
