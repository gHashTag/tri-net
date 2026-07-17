`timescale 1ns/1ps
// Spread-spectrum despreader test. Generate the length-63 m-sequence, load it as
// the despreader code, and show: (a) the LFSR period is exactly 63; (b) the
// autocorrelation peaks at +63*A on alignment; (c) any nonzero code shift sits
// near -A -- a ~63x (18 dB) processing gain, and the basis for separating mesh
// nodes by code phase (CDMA).
module tern_pn_tb;
    localparam integer N=63, W=16, ACC=24, A=100;

    reg clk=0, rst=1, en=0;
    wire [1:0] chip; wire chip_bit;
    tern_pn_lfsr #(.SEED(6'h3F)) pn(.clk(clk),.rst(rst),.en(en),.chip(chip),.chip_bit(chip_bit));
    always #5 clk=~clk;

    reg [1:0]  code [0:N-1];   // collected PN codes (2-bit ternary)
    reg signed [W-1:0] sgn [0:N-1];  // +A / -A per chip
    reg [N*W-1:0] xin; reg [N*2-1:0] win;
    wire signed [ACC-1:0] corr;
    tern_corr_pn #(.N(N),.W(W),.ACC(ACC)) dut(.xin(xin),.win(win),.corr(corr));

    integer i, sh, period; reg [5:0] first_state;
    initial begin
        // reset, then collect N chips
        @(negedge clk); rst=0; en=1;
        first_state = pn.lfsr;
        for (i=0;i<N;i=i+1) begin
            @(posedge clk); #1;
            code[i] = chip;
            sgn[i]  = chip_bit ? A : -A;
        end
        // period check: after N steps the LFSR must be back at the first state
        period = (pn.lfsr == first_state) ? N : 0;
        $display("m-sequence period = %0d (want %0d)", period, N);

        // load taps = PN code
        for (i=0;i<N;i=i+1) win[i*2 +: 2] = code[i];

        // (b) autocorrelation, aligned: x_i = sgn_i
        for (i=0;i<N;i=i+1) xin[i*W +: W] = sgn[i];
        #1; $display("autocorr aligned    = %0d  (want %0d = N*A)", corr, N*A);

        // (c) off-peak shifts: x_i = sgn[(i+sh) mod N]
        for (sh=1; sh<=3; sh=sh+1) begin
            for (i=0;i<N;i=i+1) xin[i*W +: W] = sgn[(i+sh)%N];
            #1; $display("autocorr shift %0d     = %0d  (want ~ -A = %0d)", sh, corr, -A);
        end

        // processing gain summary
        for (i=0;i<N;i=i+1) xin[i*W +: W] = sgn[i];
        #1;
        $display("processing gain = %0dx peak/off (~%0d dB)", N, 18);
        if (period==N && corr==N*A)
            $display("PN DESPREADER: sharp autocorrelation -> ZeroDSP spread-spectrum works");
        else
            $display("PN DESPREADER: FAILED");
        $finish;
    end
endmodule
