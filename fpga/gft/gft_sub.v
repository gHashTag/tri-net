`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_sub -- GF-T ladder subtract (DIFFERENT-sign add = magnitude difference),
// balanced-ternary exponent. Verified realization of specs/tri_gft_sub.t27's
// gft_sub_offset_c_p + gft_sub_mant_c_p -- the SAME spec the over-wire verifier
// runs (trinet_rung_verify, trinet_compute_over_mesh). Order by magnitude, form
// the full-precision aligned difference, and renormalize by the leading set bit
// (hi_bit). Combinational; parametric per rung. GF-T16: mant_one 512, mant_bits 9.
// ============================================================================
module gft_sub #(
    parameter [31:0] MANT_ONE  = 512,
    parameter [31:0] MANT_BITS = 9,
    parameter [31:0] ALIGN_CAP = 22
) (
    input  wire [31:0] a_off,
    input  wire [31:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [31:0] b_mant,
    output wire [31:0] out_off,
    output wire [31:0] out_mant
);
    // Index of the highest set bit of x (0..30), 0 if x<2 -- the spec's hi_bit ladder.
    function [31:0] hi_bit;
        input [31:0] x;
        integer i;
        begin
            hi_bit = 0;
            for (i = 30; i >= 1; i = i - 1)
                if (x[i] && hi_bit == 0) hi_bit = i[31:0];
        end
    endfunction
    // Normalize v (top set bit at hb) to a (mant_bits+1)-bit significand.
    function [31:0] norm_sig;
        input [31:0] v; input [31:0] hb; input [31:0] mant_bits;
        begin
            if (hb >= mant_bits) norm_sig = v >> ((hb - mant_bits) & 32'h1f);
            else                 norm_sig = v << ((mant_bits - hb) & 32'h1f);
        end
    endfunction

    // Order operands by magnitude: hi = larger (offset, then mantissa).
    wire        a_ge   = (a_off > b_off) || ((a_off == b_off) && (a_mant >= b_mant));
    wire [31:0] hi_off = a_ge ? a_off  : b_off;
    wire [31:0] hi_m   = a_ge ? a_mant : b_mant;
    wire [31:0] lo_off = a_ge ? b_off  : a_off;
    wire [31:0] lo_m   = a_ge ? b_mant : a_mant;
    wire [31:0] d      = hi_off - lo_off;

    // Far path (d >= ALIGN_CAP): the smaller operand is below one ULP -> hi minus one ULP.
    wire [31:0] far_off = (hi_m >= 1) ? hi_off : ((hi_off >= 1) ? hi_off - 1 : 32'd0);
    wire [31:0] far_m   = (hi_m >= 1) ? hi_m - 1 : MANT_ONE - 1;

    // Near path: full-precision aligned difference (u32-safe for d < ALIGN_CAP=22).
    wire [31:0] v  = ((MANT_ONE + hi_m) << d[4:0]) - (MANT_ONE + lo_m);
    wire [31:0] hb = hi_bit(v);
    wire        underflow = (lo_off + hb < MANT_BITS);
    wire [31:0] near_off = (v == 0) ? 32'd0 : (underflow ? 32'd0 : (lo_off + hb - MANT_BITS));
    wire [31:0] near_m   = (v == 0) ? 32'd0 : (underflow ? 32'd0 : (norm_sig(v, hb, MANT_BITS) - MANT_ONE));

    assign out_off  = (d >= ALIGN_CAP) ? far_off : near_off;
    assign out_mant = (d >= ALIGN_CAP) ? far_m   : near_m;
endmodule
`default_nettype wire
