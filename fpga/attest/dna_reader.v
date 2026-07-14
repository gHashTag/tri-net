// dna_reader.v — Xilinx 7-series DNA_PORT reader for A2 device attestation.
//
// Wraps the DNA_PORT primitive (UG768 §Device DNA, XAPP1082 §Device DNA
// Access) and exposes a 57-bit device DNA plus a `valid` strobe. The block
// initiates a READ pulse on start, shifts out 57 bits via DOUT, latches the
// value, and holds `valid=1` until reset.
//
// Ratchet 2/4 discipline: this module must SYNTHESISE for xc7a200t
// (AX7203, IDCODE 0x13636093) and PASS place-and-route with negative slack
// no worse than -0.5 ns at CLK_PERIOD_NS. Timing report goes into
// docs/A2_RATCHET_2_SYNTH.md.
//
// This RTL is NOT bound to any wire that would let a hostile bitstream
// forge a foreign DNA. The DOUT path is internal to the FPGA fabric; the
// only observable output is the 57-bit dna_out bus, guarded by `valid`.
//
// Spec: specs/device_dna.t27 (dna_bits_7series = 57).
//
// phi^2 + phi^-2 = 3

`timescale 1ns / 1ps
`default_nettype none

module dna_reader #(
    // Bits to shift out of DNA_PORT. 7-series = 57. UltraScale = 96 (needs
    // DNA_PORTE2 primitive, out of scope for this module).
    parameter integer DNA_BITS = 57
) (
    input  wire                     clk,
    input  wire                     rst_n,       // async low, sync deasserted
    input  wire                     start,       // pulse HIGH for >=1 clk
    output reg  [DNA_BITS-1:0]      dna_out,
    output reg                      valid
);

    // Local FSM. Four states:
    //   IDLE     — waiting for start
    //   LOAD     — assert DNA_PORT.READ for one clk
    //   SHIFT    — shift 57 bits out on DOUT
    //   HOLD     — dna_out latched, valid=1
    localparam [1:0] S_IDLE  = 2'd0,
                     S_LOAD  = 2'd1,
                     S_SHIFT = 2'd2,
                     S_HOLD  = 2'd3;

    reg [1:0]                       state;
    reg [$clog2(DNA_BITS+1)-1:0]    shift_cnt;
    reg                             shift_en;
    reg                             read_pulse;

    wire dout;

    // Xilinx 7-series DNA_PORT primitive.
    // DIN=0, tie unused. READ pulsed once to snapshot the eFUSE-programmed
    // 57-bit device DNA. SHIFT clocks bits out on DOUT (LSB first).
    DNA_PORT #(
        .SIM_DNA_VALUE(57'h123_4567_89AB_CDEF)  // sim-only; real silicon overrides
    ) u_dna_port (
        .DOUT (dout),
        .CLK  (clk),
        .DIN  (1'b0),
        .READ (read_pulse),
        .SHIFT(shift_en)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            shift_cnt  <= '0;
            shift_en   <= 1'b0;
            read_pulse <= 1'b0;
            dna_out    <= '0;
            valid      <= 1'b0;
        end else begin
            read_pulse <= 1'b0;
            shift_en   <= 1'b0;
            case (state)
                S_IDLE: begin
                    valid <= 1'b0;
                    if (start) begin
                        read_pulse <= 1'b1;
                        shift_cnt  <= '0;
                        state      <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    // READ was held HIGH for one clk in S_IDLE→S_LOAD edge.
                    // Now start shifting.
                    shift_en <= 1'b1;
                    state    <= S_SHIFT;
                end
                S_SHIFT: begin
                    shift_en <= 1'b1;
                    // MSB-first assembly: newest bit into LSB, shift left.
                    dna_out   <= {dna_out[DNA_BITS-2:0], dout};
                    shift_cnt <= shift_cnt + 1'b1;
                    if (shift_cnt == DNA_BITS-1) begin
                        shift_en <= 1'b0;
                        state    <= S_HOLD;
                    end
                end
                S_HOLD: begin
                    valid <= 1'b1;
                    // stays here until rst_n deasserts
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
