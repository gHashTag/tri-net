// gf16_corr8 -- 8-tap GoldenFloat GF16 correlator (matched filter).
//
// The radio demodulator's core op: correlate 8 received samples against 8
// reference-tone taps = sum of 8 GF16 products. Built from two gf16_dot4 MACs
// and one gf16_add -- the numeric core of the FPGA modem that replaces the
// jittery shell-toggled DDS. SSOT for the format: t27/specs/numeric/gf16.t27.
module gf16_corr8 (
    input  wire [15:0] x0, x1, x2, x3, x4, x5, x6, x7,  // received samples (GF16)
    input  wire [15:0] h0, h1, h2, h3, h4, h5, h6, h7,  // reference taps (GF16)
    output wire [15:0] corr                              // correlation (GF16)
);
    wire [15:0] lo, hi;
    gf16_dot4 dlo (.a0(x0), .a1(x1), .a2(x2), .a3(x3),
                   .b0(h0), .b1(h1), .b2(h2), .b3(h3), .result(lo));
    gf16_dot4 dhi (.a0(x4), .a1(x5), .a2(x6), .a3(x7),
                   .b0(h4), .b1(h5), .b2(h6), .b3(h7), .result(hi));
    gf16_add  acc (.a(lo), .b(hi), .result(corr));
endmodule
