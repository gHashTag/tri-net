`timescale 1ns/1ps
// Closed ZeroDSP TX->RX loop: tern_nco generates a ternary BPSK carrier, feeds
// it straight into tern_corr8_stream matched to the carrier code. The registered
// correlation must peak once per tone cycle, and the PEAK SIGN must follow the
// data bit (BPSK demod): data=1 -> large +peak, data=0 -> large -peak.
module tern_loop_tb;
    localparam integer PACC=24, W=16, ACC=20, AMP=100;
    localparam [1:0] P=2'b01, M=2'b10, Z=2'b00;
    localparam [PACC-1:0] FW8 = (1<<(PACC-3)); // 2^PACC/8 -> exactly 8 samples/cycle

    reg clk=0, rst=1, en=0, data_bit=1;
    wire signed [W-1:0] nco_sample; wire [1:0] nco_tern;
    tern_nco #(.PACC(PACC),.W(W),.AMP(AMP)) tx(.clk(clk),.rst(rst),.en(en),
        .fword(FW8),.data_bit(data_bit),.sample(nco_sample),.tern(nco_tern));

    reg rst_c=1, c_wr=0; reg [2:0] c_addr=0; reg [1:0] c_data=0;
    wire m_valid; wire signed [ACC-1:0] m_data;
    tern_corr8_stream #(.W(W),.ACC(ACC)) rx(.clk(clk),.rst(rst_c),
        .s_valid(en),.s_data(nco_sample),
        .c_wr(c_wr),.c_addr(c_addr),.c_data(c_data),
        .m_valid(m_valid),.m_data(m_data));
    always #5 clk=~clk;

    reg [1:0] code [0:7]; integer k; integer c1 [0:7]; integer c0 [0:7];
    integer align; integer best;
    initial begin
        code[0]=P;code[1]=P;code[2]=Z;code[3]=M;code[4]=M;code[5]=M;code[6]=Z;code[7]=P;
        @(negedge clk); @(negedge clk); rst=0; rst_c=0;
        // load RX taps = carrier code
        for(k=0;k<8;k=k+1) begin @(negedge clk); c_wr=1; c_addr=k[2:0]; c_data=code[k]; end
        @(negedge clk); c_wr=0;

        // ---- data bit = 1: capture one full correlation cycle (8 phases) ----
        data_bit=1; en=1;
        for(k=0;k<24;k=k+1) @(posedge clk);      // warm up pipeline + fill window
        for(k=0;k<8;k=k+1) begin @(posedge clk); #1; c1[k]=m_data; end

        // ---- data bit = 0 (carrier inverts): same 8 phases ----
        data_bit=0;
        for(k=0;k<24;k=k+1) @(posedge clk);
        for(k=0;k<8;k=k+1) begin @(posedge clk); #1; c0[k]=m_data; end
        en=0;

        // find the alignment phase (where data=1 correlation is most positive)
        align=0; best=-2000000;
        for(k=0;k<8;k=k+1) if(c1[k]>best) begin best=c1[k]; align=k; end
        $display("correlation over one cycle:");
        for(k=0;k<8;k=k+1) $display("  phase %0d: data1=%0d  data0=%0d", k, c1[k], c0[k]);
        $display("alignment phase=%0d -> data1 peak=%0d, data0 peak=%0d", align, c1[align], c0[align]);
        if (c1[align] > 3*AMP && c0[align] < -3*AMP)
            $display("BPSK demod: peak SIGN flips with the data bit -> ZeroDSP TX->RX loop closes");
        else
            $display("BPSK demod: FAILED to separate the bit");
        $finish;
    end
endmodule
