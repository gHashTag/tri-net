`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_add -- GF-T ladder adder (SAME-sign add), balanced-ternary exponent.
//
// Verified realization of specs/tri_gft_add.t27's gft_add_offset_c_p +
// gft_add_mant_c_p (via gft_add_sb_p / _offset_p / _mant_p) -- the SAME spec the
// over-wire verifier runs (trinet_rung_verify, trinet_compute_over_mesh). Align
// the smaller operand by the exponent-offset difference (barrel shift), add the
// significands, and renormalize by one carry. Combinational; parametric per rung.
// GF-T16 defaults: offset_max 80, mant_one 512, sig_bits 10 (mant_bits+1).
// ============================================================================
module gft_add #(
    parameter [31:0] OFFSET_MAX = 80,
    parameter [31:0] MANT_ONE   = 512,
    parameter [31:0] SIG_BITS   = 10
) (
    input  wire [31:0] a_off,
    input  wire [31:0] a_mant,
    input  wire [31:0] b_off,
    input  wire [31:0] b_mant,
    output wire [31:0] out_off,
    output wire [31:0] out_mant
);
    // Order operands so `hi` has the larger (or equal) exponent offset.
    wire        a_hi   = (a_off >= b_off);
    wire [31:0] hi_off = a_hi ? a_off  : b_off;
    wire [31:0] hi_m   = a_hi ? a_mant : b_mant;
    wire [31:0] lo_off = a_hi ? b_off  : a_off;
    wire [31:0] lo_m   = a_hi ? b_mant : a_mant;

    // Align the smaller significand right by the offset difference (0 if it underflows).
    wire [31:0] d  = hi_off - lo_off;
    wire [31:0] sb = (d >= SIG_BITS) ? 32'd0 : ((MANT_ONE + lo_m) >> d[4:0]);
    wire [31:0] sum = (MANT_ONE + hi_m) + sb;

    // Renormalize: a significand >= 2*mant_one carries into the exponent (+1, saturate).
    wire        carry = (sum >= (2 * MANT_ONE));
    wire [31:0] e     = hi_off + 32'd1;
    assign out_off  = carry ? ((e >= OFFSET_MAX) ? OFFSET_MAX : e) : hi_off;
    assign out_mant = carry ? ((sum >> 1) - MANT_ONE) : (sum - MANT_ONE);
endmodule
`default_nettype wire
