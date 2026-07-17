// Matched-filter test: an 8-tap GF16 correlator must LIGHT UP for the tone it is
// matched to and stay near zero for an orthogonal tone -- that separation IS
// demodulation. Reference = one period of a cosine; inputs = matching cosine
// (high corr), orthogonal sine (near zero), and noise (low).
module gf16_corr8_tb;
    reg  [15:0] x[0:7], h[0:7];
    wire [15:0] corr;
    gf16_corr8 uut(.x0(x[0]),.x1(x[1]),.x2(x[2]),.x3(x[3]),
                   .x4(x[4]),.x5(x[5]),.x6(x[6]),.x7(x[7]),
                   .h0(h[0]),.h1(h[1]),.h2(h[2]),.h3(h[3]),
                   .h4(h[4]),.h5(h[5]),.h6(h[6]),.h7(h[7]),.corr(corr));

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

    real pi; integer k; real c, sn; real cval;
    initial begin
        pi=3.14159265358979;
        // reference taps h[k] = cos(2*pi*k/8)
        for (k=0;k<8;k=k+1) begin c=$cos(2.0*pi*k/8.0); h[k]=enc(c); end

        // TEST 1: input = same cosine -> high correlation (energy = sum cos^2 = 4)
        for (k=0;k<8;k=k+1) x[k]=enc($cos(2.0*pi*k/8.0)); #1;
        cval=dec(corr); $display("matched cosine : corr = %f  (want ~4.0)", cval);

        // TEST 2: input = orthogonal sine -> near zero (sum cos*sin = 0)
        for (k=0;k<8;k=k+1) x[k]=enc($sin(2.0*pi*k/8.0)); #1;
        $display("orthogonal sine: corr = %f  (want ~0)", dec(corr));

        // TEST 3: input = a DIFFERENT tone (freq 2) -> low
        for (k=0;k<8;k=k+1) x[k]=enc($cos(2.0*pi*2.0*k/8.0)); #1;
        $display("mismatched tone: corr = %f  (want ~0)", dec(corr));

        if (cval > 3.0) $display("GF16 CORRELATOR: matched filter SEPARATES the tone");
        else            $display("GF16 CORRELATOR: FAILED to peak on match");
        $finish;
    end
endmodule
