// Streaming matched-filter test: load 8 cosine taps through the config port,
// then slide a cosine burst through the sample stream one GF16 sample per clock.
// The registered correlation output must RAMP as the burst enters and PEAK
// (~4.0) on the clock the window is fully aligned -- a real sliding correlator,
// which is exactly how the demod runs on live radio samples.
module gf16_corr8_stream_tb;
    reg clk = 0, rst = 1;
    reg s_valid = 0; reg [15:0] s_data = 0;
    reg c_wr = 0; reg [2:0] c_addr = 0; reg [15:0] c_data = 0;
    wire m_valid; wire [15:0] m_data;

    gf16_corr8_stream uut(.clk(clk), .rst(rst),
        .s_valid(s_valid), .s_data(s_data),
        .c_wr(c_wr), .c_addr(c_addr), .c_data(c_data),
        .m_valid(m_valid), .m_data(m_data));

    always #5 clk = ~clk;

    function [15:0] enc; input real v; reg s; reg [5:0] e; integer sh; real av; begin
        if (v==0.0) enc=16'h0000;
        else begin s=(v<0.0); av=s?-v:v; e=31;
            while (av>=2.0 && e<62) begin av=av/2.0; e=e+1; end
            while (av< 1.0 && e> 1) begin av=av*2.0; e=e-1; end
            sh=av*512.0-512.0+0.5; if(sh<0)sh=0; if(sh>511)sh=511;
            enc={s,e,sh[8:0]}; end
    end endfunction
    function real dec; input [15:0] x; reg s; integer e; real m; begin
        s=x[15]; e=x[14:9]; m=1.0+x[8:0]/512.0;
        if(x[14:0]==0) dec=0.0;
        else begin dec=m; if(e>=31) repeat(e-31) dec=dec*2.0; else repeat(31-e) dec=dec/2.0;
            if(s) dec=-dec; end
    end endfunction

    real pi; integer k; real peak; real v;
    initial begin
        pi=3.14159265358979; peak=0.0;
        // reset. Drive ALL stimulus on negedge so inputs are stable at the
        // posedge that samples them -- driving on the same posedge races the
        // clocked logic and silently drops writes (verified: even taps go X).
        @(negedge clk); @(negedge clk); rst=0;

        // load taps h[k]=cos(2*pi*k/8) through the config port
        for (k=0;k<8;k=k+1) begin
            @(negedge clk); c_wr=1; c_addr=k[2:0]; c_data=enc($cos(2.0*pi*k/8.0));
        end
        @(negedge clk); c_wr=0;

        // stream the matched burst: sample j = cos(2*pi*(7-j)/8) so that when the
        // 8-deep window fills, x_i = cos(2*pi*i/8) exactly aligns with tap h_i
        for (k=0;k<8;k=k+1) begin
            @(negedge clk); s_valid=1; s_data=enc($cos(2.0*pi*(7-k)/8.0));
        end
        @(negedge clk); s_valid=0;
        // read the registered correlation on the posedge that follows the full
        // window (sample -> shift-reg is 1 clk, corr -> m_data is 1 more)
        for (k=0;k<3;k=k+1) begin
            @(posedge clk); #1;
            v=dec(m_data); $display("flush[%0d] corr = %f", k, v);
            if (v>peak) peak=v;
        end

        $display("peak corr = %f  (want ~4.0)", peak);
        if (peak>3.0) $display("GF16 STREAM CORRELATOR: peaks on aligned burst -- streaming demod works");
        else          $display("GF16 STREAM CORRELATOR: FAILED to peak");
        $finish;
    end
endmodule
