`default_nettype none

// tern_nco -- ZeroDSP ternary NCO + BPSK modulator (the TX side of the modem).
//
// A phase accumulator advances by `fword` each enabled clock; the top 3 phase
// bits index an 8-entry ternary carrier sign(cos(2*pi*k/8)) = [+1,+1,0,-1,-1,
// -1,0,+1]. The carrier is ternary {-1,0,+1}, so generating it is a table
// lookup -- no multiplier, no sine ROM. `data_bit` BPSK-modulates it (1 -> the
// code, 0 -> the inverted code). Output is a signed sample in {-AMP, 0, +AMP}
// that feeds straight into tern_corr8_stream on the RX side, closing a ZeroDSP
// TX->RX loop.
//
// Tone frequency: f = (fword / 2^PACC) * Fs. For 8 samples/cycle set
// fword = 2^PACC / 8 (the carrier table has 8 phases). SSOT for the ternary
// format: t27/specs/numeric/{tf3,gfternary}.t27.
module tern_nco #(
    parameter integer PACC = 24,
    parameter integer W    = 16,
    parameter integer AMP  = 100
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              en,
    input  wire [PACC-1:0]   fword,
    input  wire              data_bit,      // BPSK: 1 -> +code, 0 -> -code
    output reg signed [W-1:0] sample,        // {-AMP, 0, +AMP}
    output reg        [1:0]  tern            // ternary code (01=+1,10=-1,00=0)
);
    localparam [1:0] P = 2'b01, M = 2'b10, Z = 2'b00;

    reg [PACC-1:0] phase;

    // 8-phase ternary carrier = sign(cos(2*pi*k/8))
    function [1:0] carrier;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: carrier = P;  3'd1: carrier = P;
                3'd2: carrier = Z;  3'd3: carrier = M;
                3'd4: carrier = M;  3'd5: carrier = M;
                3'd6: carrier = Z;  3'd7: carrier = P;
            endcase
        end
    endfunction

    // BPSK: invert the ternary code when data_bit is 0 (P<->M, Z stays)
    function [1:0] bpsk;
        input [1:0] c;
        input       d;
        begin
            if (d) bpsk = c;
            else   bpsk = (c == P) ? M : (c == M) ? P : Z;
        end
    endfunction

    wire [1:0] c_now = bpsk(carrier(phase[PACC-1 -: 3]), data_bit);

    always @(posedge clk) begin
        if (rst) begin
            phase  <= {PACC{1'b0}};
            sample <= 0;
            tern   <= Z;
        end else if (en) begin
            phase  <= phase + fword[PACC-1:0];
            tern   <= c_now;
            sample <= (c_now == P) ?  AMP[W-1:0] :
                      (c_now == M) ? -AMP[W-1:0] :
                                      {W{1'b0}};
        end
    end
endmodule

`default_nettype wire
