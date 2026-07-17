// GF16 multiplier differential sweep vs a real-valued reference (iverilog).
// This is the RTL-differential-sweep gate the CLARA erratum prescribes:
// machine math is necessary but not sufficient; sweep the realization.
module gf16_sweep_tb;
    reg  [15:0] a, b;
    wire [15:0] result;
    gf16_mul uut (.a(a), .b(b), .result(result));

    function [15:0] enc; input real v; reg s; reg [5:0] e; integer sh; real av; begin
        if (v == 0.0) enc = 16'h0000;
        else begin
            s = (v < 0.0); av = s ? -v : v; e = 31;
            while (av >= 2.0 && e < 62) begin av = av/2.0; e = e+1; end
            while (av <  1.0 && e >  1) begin av = av*2.0; e = e-1; end
            sh = av*512.0 - 512.0 + 0.5;
            if (sh < 0) sh = 0; if (sh > 511) sh = 511;
            enc = {s, e, sh[8:0]};
        end
    end endfunction

    function real dec; input [15:0] x; reg s; integer e; real m; begin
        s = x[15]; e = x[14:9]; m = 1.0 + x[8:0]/512.0;
        if (x[14:0] == 0) dec = 0.0;
        else begin
            dec = m; if (e >= 31) begin repeat (e-31) dec = dec*2.0; end
            else begin repeat (31-e) dec = dec/2.0; end
            if (s) dec = -dec;
        end
    end endfunction

    integer i, j, npass, nfail; real va, vb, got, want, err, tol;
    real vals [0:19];
    initial begin
        vals[0]=1.0;  vals[1]=2.0;  vals[2]=0.5;  vals[3]=1.5;  vals[4]=3.0;
        vals[5]=0.25; vals[6]=4.0;  vals[7]=1.25; vals[8]=1.75; vals[9]=6.0;
        vals[10]=0.125; vals[11]=8.0; vals[12]=1.618; vals[13]=2.618; vals[14]=0.382;
        vals[15]=10.0; vals[16]=0.75; vals[17]=1.1; vals[18]=16.0; vals[19]=0.0625;
        npass=0; nfail=0;
        for (i=0;i<20;i=i+1) for (j=0;j<20;j=j+1) begin
            va=vals[i]; vb=vals[j]; a=enc(va); b=enc(vb); #1;
            got=dec(result); want=va*vb;
            err = got-want; if (err<0.0) err=-err;
            tol = want/256.0; if (tol<0.0) tol=-tol; if (tol<0.001) tol=0.001;
            if (err<=tol) npass=npass+1;
            else begin nfail=nfail+1;
              if (nfail<=6) $display("  FAIL %f * %f = %f (want %f)", va, vb, got, want); end
        end
        $display("SWEEP: %0d pass, %0d fail  (%0d pairs, tol=1/256)", npass, nfail, npass+nfail);
        $display(nfail==0 ? "GF16 MUL: CLEAN over the sweep" : "GF16 MUL: DEFECTS FOUND");
        $finish;
    end
endmodule
