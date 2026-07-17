// Feed REAL over-the-air samples (captured from board .12 while .13 transmits a
// 1 MHz tone) through the actual synthesizable gf16_corr8_stream RTL. Matched
// taps must produce a large correlation swing; mismatched taps or the TX-off
// capture must stay near the noise floor. Files come in via +SAMP= and +TAPS=.
module ota_corr_tb;
    reg clk=0,rst=1; reg s_valid=0; reg [15:0] s_data=0;
    reg c_wr=0; reg [2:0] c_addr=0; reg [15:0] c_data=0;
    wire m_valid; wire [15:0] m_data;
    gf16_corr8_stream uut(.clk(clk),.rst(rst),.s_valid(s_valid),.s_data(s_data),
        .c_wr(c_wr),.c_addr(c_addr),.c_data(c_data),.m_valid(m_valid),.m_data(m_data));
    always #5 clk=~clk;
    function real dec; input [15:0] x; reg s; integer e; real m; begin
        s=x[15]; e=x[14:9]; m=1.0+x[8:0]/512.0;
        if(x[14:0]==0) dec=0.0; else begin dec=m;
        if(e>=31) repeat(e-31) dec=dec*2.0; else repeat(31-e) dec=dec/2.0; if(s)dec=-dec; end
    end endfunction

    reg [15:0] samp [0:2047];
    reg [15:0] taps [0:7];
    reg [1023:0] sfile, tfile;
    integer k, nsamp; real v, peak, sumsq; integer cnt;
    initial begin
        if(!$value$plusargs("SAMP=%s", sfile)) sfile="rx_on.hex";
        if(!$value$plusargs("TAPS=%s", tfile)) tfile="taps_match.hex";
        if(!$value$plusargs("N=%d", nsamp)) nsamp=1024;
        $readmemh(sfile, samp);
        $readmemh(tfile, taps);
        peak=0.0; sumsq=0.0; cnt=0;
        @(negedge clk); @(negedge clk); rst=0;
        // load taps via config port on negedge (avoid the write race)
        for(k=0;k<8;k=k+1) begin @(negedge clk); c_wr=1; c_addr=k[2:0]; c_data=taps[k]; end
        @(negedge clk); c_wr=0;
        // stream the real samples
        for(k=0;k<nsamp;k=k+1) begin
            @(negedge clk); s_valid=1; s_data=samp[k];
            @(posedge clk); #1;                     // registered corr for prev window
            v=dec(m_data); if(v<0) v=-v;
            if(v>peak) peak=v;
            if(k>=16) begin sumsq=sumsq+v*v; cnt=cnt+1; end  // skip pipeline warmup
        end
        @(negedge clk); s_valid=0;
        $display("SAMP=%0s TAPS=%0s  peak|corr|=%f  rms|corr|=%f", sfile, tfile, peak, (cnt>0)?$sqrt(sumsq/cnt):0.0);
        $finish;
    end
endmodule
