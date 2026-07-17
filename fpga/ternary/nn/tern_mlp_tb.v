`timescale 1ns/1ps
// Run the WHOLE trained ternary net through tern_mlp end-to-end for 6 held-out
// samples: load weights + features, pulse start, read class + cycle count.
module tern_mlp_tb;
    localparam K1=27,M1=16,K2=16,M2=3,W=8,ACC=16;
    reg clk=0,rst=1,start=0; reg [K1*W-1:0] x; reg [M1*K1*2-1:0] w1; reg [M2*K2*2-1:0] w2;
    wire done; wire [1:0] class_id; wire signed [ACC-1:0] y0,y1,y2; wire [7:0] cycles;
    tern_mlp #(.K1(K1),.M1(M1),.K2(K2),.M2(M2),.W(W),.ACC(ACC)) dut(
        .clk(clk),.rst(rst),.start(start),.x(x),.w1(w1),.w2(w2),
        .done(done),.class_id(class_id),.y0(y0),.y1(y1),.y2(y2),.cycles(cycles));
    always #5 clk=~clk;

    reg [1:0] w1c [0:M1*K1-1]; reg [1:0] w2c [0:M2*K2-1];
    reg signed [W-1:0] xv [0:K1-1];
    integer s,i; reg [255:0] fn; reg [1:0] exp [0:5];
    reg [23:0] names [0:2];
    initial begin
        names[0]="ton"; names[1]="pn_"; names[2]="off";
        exp[0]=0;exp[1]=0;exp[2]=1;exp[3]=0;exp[4]=0;exp[5]=1;   // true labels
        $readmemh({"", "nn_W1.hex"}, w1c); $readmemh("nn_W2.hex", w2c);
        for(i=0;i<M1*K1;i=i+1) w1[i*2 +: 2]=w1c[i];
        for(i=0;i<M2*K2;i=i+1) w2[i*2 +: 2]=w2c[i];
        @(negedge clk); rst=0;
        for(s=0;s<6;s=s+1) begin
            $sformat(fn,"nn_x%0d.hex",s); $readmemh(fn,xv);
            for(i=0;i<K1;i=i+1) x[i*W +: W]=xv[i];
            @(negedge clk); start=1; @(negedge clk); start=0;
            wait(done); @(negedge clk);
            $display("sample %0d: class=%0s  y=(%0d,%0d,%0d)  cycles=%0d  expected=%0s  %s",
                s, names[class_id], y0,y1,y2, cycles, names[exp[s]],
                (class_id==exp[s])?"OK":"MISMATCH");
        end
        $finish;
    end
endmodule
