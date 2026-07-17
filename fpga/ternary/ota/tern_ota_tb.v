`timescale 1ns/1ps
// Feed REAL over-the-air samples (board .12 RX while .13 transmits a 1 MHz tone,
// decimated by 4 to 8 samples/cycle) through the ZeroDSP ternary correlator.
// The matched ternary code sign(cos(2*pi*k/8)) must swing large; a mismatched
// (3x) ternary code or the TX-off capture must stay near the floor. Samples are
// raw signed int16 from iio_readdev (no float encode -- ternary needs none).
// +SAMP=<hexfile>  +CODE=0(matched)/1(mismatched)  +N=<count>
module tern_ota_tb;
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

    reg signed [W-1:0] samp [0:2047];
    reg [1:0] match_c [0:7];
    reg [1:0] mis_c   [0:7];
    reg [1:0] code [0:7];
    reg [1023:0] sfile; integer which, nsamp, k; real peak, sumsq; integer cnt; real v;

    initial begin
        // matched = sign(cos(2*pi*k/8)); mismatched = sign(cos(2*pi*3*k/8))
        match_c[0]=P;match_c[1]=P;match_c[2]=Z;match_c[3]=M;match_c[4]=M;match_c[5]=M;match_c[6]=Z;match_c[7]=P;
        mis_c[0]=P;  mis_c[1]=M;  mis_c[2]=Z;  mis_c[3]=P;  mis_c[4]=M;  mis_c[5]=P;  mis_c[6]=Z;  mis_c[7]=M;
        if(!$value$plusargs("SAMP=%s", sfile)) sfile="rx_on_raw.hex";
        if(!$value$plusargs("CODE=%d", which)) which=0;
        if(!$value$plusargs("N=%d", nsamp)) nsamp=256;
        for(k=0;k<8;k=k+1) code[k] = which ? mis_c[k] : match_c[k];
        $readmemh(sfile, samp);

        peak=0.0; sumsq=0.0; cnt=0;
        @(negedge clk); @(negedge clk); rst=0;
        for(k=0;k<8;k=k+1) begin @(negedge clk); c_wr=1; c_addr=k[2:0]; c_data=code[k]; end
        @(negedge clk); c_wr=0;
        for(k=0;k<nsamp;k=k+1) begin
            @(negedge clk); s_valid=1; s_data=samp[k];
            @(posedge clk); #1;
            v=m_data; if(v<0) v=-v;
            if(v>peak) peak=v;
            if(k>=16) begin sumsq=sumsq+v*v; cnt=cnt+1; end
        end
        @(negedge clk); s_valid=0;
        $display("SAMP=%0s CODE=%0d  peak|corr|=%0d  rms|corr|=%.1f", sfile, which, peak, (cnt>0)?$sqrt(sumsq/cnt):0.0);
        $finish;
    end
endmodule
