`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_add64 -- GF-T64 (wide) ladder adder, SAME-sign add. The 128-bit-datapath
// realization of specs/tri_gft_add.t27 for a 64-bit mantissa: gft_add is 32-bit
// (fine to GF-T16) and gft_mul32/gft_add cover GF-T32, but at GF-T64 the significand
// (2^64 + m) and its sum (up to ~2^66) overflow 32/64 bits -- so the significand path
// widens to 128 bits (offset stays narrow, <= 19682). Same align/add/one-carry-renorm.
//
// GF-T64: offset_max 19682, mant_one 2^64, sig_bits 65 (mant_bits 64 + 1).
// value = (1 + M/2^64) * 2^(offset - 9841).
// ============================================================================
module gft_add64 #(
    parameter [31:0]  OFFSET_MAX = 32'd19682,
    parameter [127:0] MANT_ONE   = 128'h1_0000_0000_0000_0000,  // 2^64
    parameter [31:0]  SIG_BITS   = 32'd65
) (
    input  wire [31:0] a_off,
    input  wire [63:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [63:0] b_mant,
    output wire [31:0] out_off,
    output wire [63:0] out_mant
);
    // Order operands so `hi` has the larger (or equal) exponent offset.
    wire        a_hi   = (a_off >= b_off);
    wire [31:0] hi_off = a_hi ? a_off  : b_off;
    wire [63:0] hi_m   = a_hi ? a_mant : b_mant;
    wire [31:0] lo_off = a_hi ? b_off  : a_off;
    wire [63:0] lo_m   = a_hi ? b_mant : a_mant;

    // Align the smaller significand right by the offset difference (0 if it underflows).
    wire [31:0]  d  = hi_off - lo_off;
    wire [127:0] sb = (d >= SIG_BITS) ? 128'd0 : ((MANT_ONE + {64'd0, lo_m}) >> d[6:0]);
    wire [127:0] sum = (MANT_ONE + {64'd0, hi_m}) + sb;

    // Renormalize: a significand >= 2*mant_one carries into the exponent (+1, saturate).
    wire         carry = (sum >= (2 * MANT_ONE));
    wire [31:0]  e     = hi_off + 32'd1;
    assign out_off  = carry ? ((e >= OFFSET_MAX) ? OFFSET_MAX : e) : hi_off;
    wire [127:0] m_c = (sum >> 1) - MANT_ONE;
    wire [127:0] m_n = sum - MANT_ONE;
    assign out_mant = carry ? m_c[63:0] : m_n[63:0];
endmodule
`default_nettype wire
