`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul64 -- GF-T64 multiplier (PROPOSED rung, from the Fibonacci ladder rule).
//
// The golden rule (tests/goldenfloat_ternary_ladder.rs) puts GF-T64 at Et = 9 exponent
// trits (offset_max = 3^9-1 = 19682, bias 9841) and a 64-bit mantissa (mant_one = 2^64).
// The significand product (2^64 + m)^2 reaches ~2^130, so gft_mul64 carries a 256-bit
// internal product path (gft_mul32 needed 64-bit; gft_mul needed 32-bit -- the datapath
// doubles with the mantissa). Same round-toward-zero renormalization as every rung.
//
// PROPOSED: GF-T64 fits the Fibonacci rule that reproduces all four sealed rungs (GF-T4/8/
// 16/32); its ratification is the SSOT's. This RTL realizes the arithmetic proven exact in
// BigUint for a 64-bit mantissa. Combinational. Operands: offset (up to 19682, 15 bits) +
// mantissa (64 bits). value = (1 + M/2^64) * 2^(offset - 9841).
// ============================================================================
module gft_mul64 #(
    parameter [31:0]  BIAS       = 32'd9841,
    parameter [31:0]  OFFSET_MAX = 32'd19682,
    parameter [127:0] MANT_ONE   = 128'h1_0000_0000_0000_0000  // 2^64
) (
    input  wire [31:0] a_off,
    input  wire [63:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [63:0] b_mant,
    output wire [31:0] out_off,
    output wire [63:0] out_mant
);
    // 256-bit significand product (1+M/mant_one) scaled by mant_one^2 (~2^130).
    wire [255:0] prod   = (MANT_ONE + {64'd0, a_mant}) * (MANT_ONE + {64'd0, b_mant});
    wire [255:0] thresh = (2 * MANT_ONE) * MANT_ONE;      // one-bit renorm boundary (~2^129)
    wire         carry  = (prod >= thresh);

    // Exponent offset: narrow arithmetic (offsets <= 19682, carry 0/1).
    wire [31:0] sum    = a_off + b_off + {31'd0, carry};
    wire [31:0] result = sum - BIAS;
    assign out_off = (sum < BIAS)           ? 32'd0 :
                     (result >= OFFSET_MAX) ? OFFSET_MAX : result;

    // Mantissa: renormalize by the carry (divisors are constant powers of two).
    wire [255:0] m_hi = (prod / (2 * MANT_ONE)) - MANT_ONE;
    wire [255:0] m_lo = (prod /      MANT_ONE ) - MANT_ONE;
    assign out_mant = carry ? m_hi[63:0] : m_lo[63:0];
endmodule
`default_nettype wire
