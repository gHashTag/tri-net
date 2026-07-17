`default_nettype none
// tern_rmsnorm -- RMSNorm: y_i = x_i / sqrt(mean(x^2)), scaled to Q(OUTQ). The
// inverse square root is a 4096-entry ROM (no multiplier, no iteration) -- the
// non-MAC primitive, like CORDIC. Honest DSP: the sum-of-squares (x_i^2) and the
// scale (x_i * inv) are activation x activation, so they need multipliers --
// RMSNorm is a data-dependent op like attention's Q.K^T, not a ternary matmul.
// The rsqrt itself is 0 DSP. SSOT: t27/specs/igla/coder/arch.t27.
module tern_rmsnorm #(parameter integer N=8, parameter integer W=8,
                      parameter integer OUTQ=6, parameter integer LOG2N=3)
  (input wire signed [N*W-1:0] x, output wire signed [N*(W+OUTQ)-1:0] y);
    reg [15:0] rsqrt [0:4095];
    initial $readmemh("rsqrt_lut.hex", rsqrt);
    integer i;
    reg signed [W-1:0]     xi;
    reg signed [2*W-1:0]   sq;          // wide square (up to 127^2)
    reg [31:0]             ss;
    reg [11:0]             ms;
    reg [15:0]             inv;
    reg signed [W+17-1:0]  prod;        // wide scale product
    reg signed [W+OUTQ-1:0] yo [0:N-1];
    always @(*) begin
        ss = 0;
        for (i=0;i<N;i=i+1) begin
            xi = x[i*W +: W];
            sq = xi * xi;                            // 16-bit context -> correct
            ss = ss + sq;
        end
        ms  = ((ss >> LOG2N) == 0) ? 12'd1 :
              ((ss >> LOG2N) > 4095) ? 12'd4095 : (ss >> LOG2N);
        inv = rsqrt[ms];                             // Q12 rsqrt (0 DSP ROM)
        for (i=0;i<N;i=i+1) begin
            xi   = x[i*W +: W];
            prod = xi * $signed({1'b0, inv});        // wide product
            yo[i] = prod >>> (12 - OUTQ);
        end
    end
    genvar g; generate for (g=0;g<N;g=g+1) begin: o
        assign y[g*(W+OUTQ) +: (W+OUTQ)] = yo[g]; end endgenerate
endmodule
`default_nettype wire
