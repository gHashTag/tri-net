`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul32 -- GF-T32 (top rung) ladder multiplier, 64-bit mantissa datapath.
//
// gft_mul.v is 32-bit internally: fine for GF-T16 (mant_one 512, product ~2^20)
// but it SILENTLY OVERFLOWS at the top rung, where mant_one = 2^25 and the
// significand product reaches ~2^52. This is the wide-datapath realization of the
// SAME spec (specs/tri_gft_arith.t27 gft_mul_*_u64) -- offset stays narrow, only the
// significand path widens to 64 bits.
//
// GF-T32 defaults: bias 364, offset_max 728, mant_one 2^25. value = (1 + M/2^25) *
// 2^(offset - 364), e in [-364, 364]. Parametric, so it also covers any wide rung.
// ============================================================================
module gft_mul32 #(
    parameter [31:0] BIAS       = 364,
    parameter [31:0] OFFSET_MAX = 728,
    parameter [63:0] MANT_ONE   = 64'd33554432   // 2^25
) (
    input  wire [31:0] a_off,
    input  wire [31:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [31:0] b_mant,
    output wire [31:0] out_off,
    output wire [31:0] out_mant
);
    // 64-bit significand product (1+M/mant_one) scaled by mant_one^2 -- up to ~2^52.
    wire [63:0] prod   = (MANT_ONE + {32'd0, a_mant}) * (MANT_ONE + {32'd0, b_mant});
    wire [63:0] thresh = (2 * MANT_ONE) * MANT_ONE;      // one-bit renorm boundary (~2^51)
    wire        carry  = (prod >= thresh);

    // Exponent offset: narrow arithmetic (offsets <= 728, carry 0/1).
    wire [31:0] sum    = a_off + b_off + {31'd0, carry};
    wire [31:0] result = sum - BIAS;
    assign out_off = (sum < BIAS)           ? 32'd0 :
                     (result >= OFFSET_MAX) ? OFFSET_MAX : result;

    // Mantissa: renormalize by the carry (divisors are constant powers of two).
    wire [63:0] m_hi = (prod / (2 * MANT_ONE)) - MANT_ONE;
    wire [63:0] m_lo = (prod /      MANT_ONE ) - MANT_ONE;
    assign out_mant = carry ? m_hi[31:0] : m_lo[31:0];
endmodule
`default_nettype wire
