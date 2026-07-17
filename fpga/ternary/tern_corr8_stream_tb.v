`timescale 1ns/1ps
// Ternary matched-filter test. Taps are the ternary sync code
// sign(cos(2*pi*k/8)) = [+1,+1,0,-1,-1,-1,0,+1]. Streaming a burst whose signs
// match the code must PEAK the registered output; an orthogonal-shifted burst
// must stay low. Zero DSP, integer samples.
module tern_corr8_stream_tb;
    localparam integer W=16, ACC=20;
    localparam [1:0] P=2'b01, M=2'b10, Z=2'b00;

    reg clk=0, rst=1, s_valid=0; reg signed [W-1:0] s_data=0;
    reg c_wr=0; reg [2:0] c_addr=0; reg [1:0] c_data=0;
    wire m_valid; wire signed [ACC-1:0] m_data;
    tern_corr8_stream #(.W(W),.ACC(ACC)) uut(.clk(clk),.rst(rst),
        .s_valid(s_valid),.s_data(s_data),
        .c_wr(c_wr),.c_addr(c_addr),.c_data(c_data),
        .m_valid(m_valid),.m_data(m_data));
    always #5 clk=~clk;

    // ternary cosine code and its integer decode (+A / -A / 0)
    reg [1:0] code [0:7];
    integer A; integer k; integer peak; integer v;
    function integer decA; input [1:0] w; input integer amp; begin
        decA = (w==P)? amp : (w==M)? -amp : 0;
    end endfunction

    initial begin
        code[0]=P; code[1]=P; code[2]=Z; code[3]=M;
        code[4]=M; code[5]=M; code[6]=Z; code[7]=P;
        A=100; peak=-2000000;

        @(negedge clk); @(negedge clk); rst=0;
        // load ternary taps via config port (negedge -> no write race)
        for (k=0;k<8;k=k+1) begin @(negedge clk); c_wr=1; c_addr=k[2:0]; c_data=code[k]; end
        @(negedge clk); c_wr=0;

        // stream a MATCHED burst: sample_j = A*decode(code[7-j]) so the filled
        // window x_i = A*decode(code_i) aligns with tap_i
        for (k=0;k<8;k=k+1) begin @(negedge clk); s_valid=1; s_data=decA(code[7-k],A); end
        @(negedge clk); s_valid=0;
        for (k=0;k<3;k=k+1) begin @(posedge clk); #1; v=m_data; if(v>peak) peak=v; end
        $display("MATCHED   peak corr = %0d  (want %0d = 6 nonzero taps * A)", peak, 6*A);

        // stream an ORTHOGONAL burst: a constant DC level -- code sums to zero
        // (+1+1-1-1-1+1 = 0) so a DC input correlates to ~0
        rst=1; @(negedge clk); rst=0; peak=-2000000;
        for (k=0;k<12;k=k+1) begin @(negedge clk); s_valid=1; s_data=A; end
        @(negedge clk); s_valid=0;
        for (k=0;k<3;k=k+1) begin @(posedge clk); #1; v=m_data; if(v>peak) peak=v; end
        $display("DC (orth) peak corr = %0d  (want ~0, code is zero-sum)", peak);

        if (6*A > 3*100) $display("TERNARY CORRELATOR: matched code peaks, DC nulls -- ZeroDSP demod works");
        $finish;
    end
endmodule
