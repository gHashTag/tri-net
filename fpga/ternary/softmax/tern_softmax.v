`default_nettype none

// tern_softmax -- fixed-point softmax, the last non-MAC piece of attention.
//   p_i = exp(x_i - max) / sum_j exp(x_j - max)
// exp comes from a 128-entry ROM (no multiplier); the normalisation is an
// integer divide (LUT-mapped, still zero DSP). Logits are Q2 (x = 4*real), the
// exp table is Q16, and the outputs are Q16 probabilities that sum to ~65536.
//
// Softmax completes the attention block: scores -> tern_softmax -> weights, then
// weights . V via the systolic GEMM. SSOT: t27/specs/igla/coder/arch.t27.
module tern_softmax #(
    parameter integer N    = 8,    // vector length
    parameter integer LOGW = 12,   // signed logit width (Q2)
    parameter integer PW   = 17    // Q16 probability width (0..65536)
) (
    input  wire signed [N*LOGW-1:0] x,
    output wire        [N*PW-1:0]   prob
);
    reg [15:0] lut [0:127];
    initial $readmemh("exp_lut.hex", lut);

    integer i;
    reg signed [LOGW-1:0] xi, mx;
    reg [7:0]  d;
    reg [15:0] e [0:N-1];
    reg [31:0] sum;
    reg [PW-1:0] p [0:N-1];

    always @(*) begin
        // max
        mx = x[0 +: LOGW];
        for (i = 1; i < N; i = i + 1) begin
            xi = x[i*LOGW +: LOGW];
            if (xi > mx) mx = xi;
        end
        // exp(x_i - max) via ROM (d = max - x_i >= 0, clamped to table range)
        sum = 32'd0;
        for (i = 0; i < N; i = i + 1) begin
            xi = x[i*LOGW +: LOGW];
            d  = (mx - xi > 127) ? 8'd127 : (mx - xi);
            e[i] = lut[d];
            sum  = sum + e[i];
        end
        // normalise: p_i = e_i * 2^16 / sum  (Q16, LUT-mapped divide, no DSP)
        for (i = 0; i < N; i = i + 1)
            p[i] = ({e[i], 16'd0}) / sum;
    end

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_out
            assign prob[g*PW +: PW] = p[g];
        end
    endgenerate
endmodule

`default_nettype wire
