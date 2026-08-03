`default_nettype none

// tern_corr_pn -- parameterised N-tap ZeroDSP ternary despreader.
//
// Same sign-select principle as tern_corr8, scaled to a full PN code: taps are
// the N-chip ternary spreading code, samples are the received chips. On code
// alignment the correlation is the autocorrelation peak (+N for an m-sequence);
// off alignment, or against a different code, it collapses toward zero. That
// ratio IS the processing gain that lets a spread signal survive jammers and
// separates mesh nodes by code (CDMA). Still zero DSP -- a signed adder tree.
//
// Ports are packed (pre-SystemVerilog-array friendly): xin/win are the N
// samples / N 2-bit taps concatenated low-index-first. SSOT for the ternary
// format: t27/specs/numeric/gfternary.t27.
module tern_corr_pn #(
    parameter integer N   = 63,
    parameter integer W   = 16,
    parameter integer ACC = 24
) (
    input  wire [N*W-1:0]        xin,   // N packed signed samples
    input  wire [N*2-1:0]        win,   // N packed ternary taps
    output wire signed [ACC-1:0] corr
);
    integer i;
    reg signed [ACC-1:0] acc;
    reg signed [W-1:0]   xi;
    reg        [1:0]     wi;

    always @(*) begin
        acc = {ACC{1'b0}};
        for (i = 0; i < N; i = i + 1) begin
            xi = xin[i*W +: W];
            wi = win[i*2 +: 2];
            case (wi)
                2'b01: acc = acc + {{(ACC-W){xi[W-1]}}, xi};
                2'b10: acc = acc - {{(ACC-W){xi[W-1]}}, xi};
                default: acc = acc;   // 0 tap contributes nothing
            endcase
        end
    end

    assign corr = acc;
endmodule

`default_nettype wire
