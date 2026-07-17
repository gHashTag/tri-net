module nn_layer_tb;
  parameter M=16, K=27, W=8, ACC=16;
  reg [1:0] wcode [0:M*K-1];
  reg signed [W-1:0] a [0:K-1];
  reg [K*W-1:0] act; reg [M*K*2-1:0] wts;
  wire [M*ACC-1:0] out;
  tern_matvec #(.M(M),.K(K),.W(W),.ACC(ACC)) dut(.act(act),.wts(wts),.out(out));
  reg [1023:0] wf, af; integer m,k; reg signed [ACC-1:0] o;
  initial begin
    if(!$value$plusargs("WF=%s",wf)) wf="nn_W1.hex";
    if(!$value$plusargs("AF=%s",af)) af="nn_x0.hex";
    $readmemh(wf,wcode); $readmemh(af,a);
    for(m=0;m<M;m=m+1) for(k=0;k<K;k=k+1) wts[(m*K+k)*2 +: 2]=wcode[m*K+k];
    for(k=0;k<K;k=k+1) act[k*W +: W]=a[k];
    #1;
    for(m=0;m<M;m=m+1) begin o=out[m*ACC +: ACC]; $write("%0d ",o); end
    $display(""); $finish;
  end
endmodule
