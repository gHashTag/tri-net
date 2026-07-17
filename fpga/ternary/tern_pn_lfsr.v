`default_nettype none

// tern_pn_lfsr -- maximal-length (m-sequence) PN generator, ternary output.
//
// A 6-bit Fibonacci LFSR with the primitive polynomial x^6 + x^5 + 1 cycles
// through all 63 nonzero states (period 2^6-1 = 63) before repeating. Each clock
// emits one PN chip mapped to a ternary code: 1 -> +1 (2'b01), 0 -> -1 (2'b10).
// A PN chip is never 0, so the "ternary" code here uses only the +/-1 points --
// the despreader (tern_corr_pn) is the same ZeroDSP sign-select correlator.
//
// Spreading a data bit by this code and correlating on the far side gives a
// processing gain of N = 63 (~18 dB): the autocorrelation peaks at +63 on
// alignment and sits at -1 off it, so a weak signal buried under jammers or
// another node's code still pops out. SSOT: t27/specs/numeric/gfternary.t27.
module tern_pn_lfsr #(
    parameter [5:0] SEED = 6'h3F
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       en,
    output wire [1:0] chip,     // ternary chip: 2'b01=+1, 2'b10=-1
    output wire       chip_bit  // raw PN bit (1/0)
);
    reg [5:0] lfsr;
    wire fb = lfsr[5] ^ lfsr[4];   // x^6 + x^5 + 1

    always @(posedge clk) begin
        if (rst)      lfsr <= SEED;
        else if (en)  lfsr <= {lfsr[4:0], fb};
    end

    assign chip_bit = lfsr[5];
    assign chip     = lfsr[5] ? 2'b01 : 2'b10;   // 1->+1, 0->-1
endmodule

`default_nettype wire
