`default_nettype none

// tern_corr8 -- ZeroDSP 8-tap ternary matched filter (radio demod core).
//
// The GF16 correlator (fpga/gf16/gf16_corr8) costs 8 DSP48E1 because every tap
// is a full floating-point multiply. But a matched filter's reference is a
// spreading/sync CODE, and a code is naturally ternary {-1, 0, +1}. Multiplying
// a received sample by a ternary tap is NOT a multiply -- it is a sign-select:
//
//     tap = +1  ->  + x
//     tap = -1  ->  - x
//     tap =  0  ->    0
//
// So corr = sum_k tap_k * x_k = (sum of x where tap=+1) - (sum where tap=-1):
// a signed adder tree, ZERO DSP, ZERO float normalization. This is the t27
// "ZeroDSP MAC" idea (t27/specs/fpga/mac.t27, t27/fpga/verilog/
// ternary_mac_synth.v) applied to the radio matched filter. Ternary weight
// encoding follows GFTernary / that MAC: 2'b01 -> +1, 2'b10 -> -1, else 0.
//
// SSOT for the ternary formats: t27/specs/numeric/{tf3,gfternary}.t27,
// t27/specs/fpga/mac.t27.
module tern_corr8 #(
    parameter integer W   = 16,   // signed sample width (AD9361 I, sign-extended)
    parameter integer ACC = 20    // accumulator width (W + ceil(log2(8)) headroom)
) (
    input  wire signed [W-1:0] x0, x1, x2, x3, x4, x5, x6, x7,  // received samples
    input  wire        [1:0]   w0, w1, w2, w3, w4, w5, w6, w7,  // ternary taps
    output wire signed [ACC-1:0] corr                            // correlation
);
    // one ternary tap applied to one sample: +x, -x, or 0 (sign-extended to ACC)
    function signed [ACC-1:0] term;
        input signed [W-1:0] x;
        input        [1:0]   w;
        reg signed [ACC-1:0] xe;
        begin
            xe   = {{(ACC-W){x[W-1]}}, x};
            term = (w == 2'b01) ?  xe :
                   (w == 2'b10) ? -xe :
                                   {ACC{1'b0}};
        end
    endfunction

    assign corr = term(x0,w0) + term(x1,w1) + term(x2,w2) + term(x3,w3)
                + term(x4,w4) + term(x5,w5) + term(x6,w6) + term(x7,w7);
endmodule

`default_nettype wire
