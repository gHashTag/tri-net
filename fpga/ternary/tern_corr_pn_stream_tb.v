`timescale 1ns/1ps
// Stream the length-63 PN through the streaming despreader: after the window
// fills with the aligned code, the registered output must hit the autocorrelation
// peak N*A, then fall away as the code slides out.
module tern_corr_pn_stream_tb;
    localparam integer N=63, W=16, ACC=24, AW=6, A=100;
    localparam [1:0] P=2'b01, M=2'b10;

    reg clk=0, rst=1, s_valid=0; reg signed [W-1:0] s_data=0;
    reg c_wr=0; reg [AW-1:0] c_addr=0; reg [1:0] c_data=0;
    wire m_valid; wire signed [ACC-1:0] m_data;
    tern_corr_pn_stream #(.N(N),.W(W),.ACC(ACC),.AW(AW)) uut(.clk(clk),.rst(rst),
        .s_valid(s_valid),.s_data(s_data),.c_wr(c_wr),.c_addr(c_addr),.c_data(c_data),
        .m_valid(m_valid),.m_data(m_data));
    always #5 clk=~clk;

    reg [1:0] code [0:N-1]; reg signed [W-1:0] sgn [0:N-1];
    integer k, peak, v; reg [5:0] lf;
    initial begin
        // generate PN (same LFSR as tern_pn_lfsr): seed 0x3F, fb=lf[5]^lf[4]
        lf=6'h3F;
        for(k=0;k<N;k=k+1) begin
            code[k] = lf[5] ? P : M;
            sgn[k]  = lf[5] ? A : -A;
            lf = {lf[4:0], lf[5]^lf[4]};
        end
        @(negedge clk); @(negedge clk); rst=0;
        // load taps (negedge -> no write race)
        for(k=0;k<N;k=k+1) begin @(negedge clk); c_wr=1; c_addr=k[AW-1:0]; c_data=code[k]; end
        @(negedge clk); c_wr=0;
        // stream the aligned PN: sample_j = sgn[N-1-j] so window xr[i]=sgn[i]
        peak=-2000000;
        for(k=0;k<N;k=k+1) begin @(negedge clk); s_valid=1; s_data=sgn[N-1-k]; end
        @(negedge clk); s_valid=0;
        for(k=0;k<4;k=k+1) begin @(posedge clk); #1; v=m_data; if(v>peak)peak=v; end
        $display("PN despreader stream: peak=%0d  (want %0d = N*A)", peak, N*A);
        if (peak==N*A) $display("STREAMING PN DESPREADER: autocorrelation peak on alignment -- OK");
        else           $display("STREAMING PN DESPREADER: FAILED");
        $finish;
    end
endmodule
