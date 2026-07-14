// dna_port_model.v — behavioural stand-in for Xilinx UNISIM DNA_PORT.
//
// Used ONLY for iverilog sandbox simulation. Real synthesis pulls the
// vendor UNISIM library instead. Semantics match UG768 §Device DNA and
// XAPP1082 §Device DNA Access:
//   - READ pulse (HIGH ≥1 clk): snapshot the 57-bit DNA into internal reg.
//   - SHIFT held HIGH: emit one DNA bit per clk on DOUT (LSB first).
//   - DIN unused in read-only mode.
//
// The SIM_DNA_VALUE parameter matches the real UNISIM knob so the wrapper
// code stays identical.
//
// phi^2 + phi^-2 = 3

`timescale 1ns / 1ps

module DNA_PORT #(
    parameter [56:0] SIM_DNA_VALUE = 57'h123_4567_89AB_CDEF
) (
    output wire DOUT,
    input  wire CLK,
    input  wire DIN,
    input  wire READ,
    input  wire SHIFT
);
    reg [56:0] dna_reg;
    reg        loaded;

    initial begin
        dna_reg = 57'h0;
        loaded  = 1'b0;
    end

    assign DOUT = dna_reg[0];

    always @(posedge CLK) begin
        if (READ) begin
            dna_reg <= SIM_DNA_VALUE;
            loaded  <= 1'b1;
        end else if (SHIFT && loaded) begin
            // LSB-first shift-out, matches UNISIM semantics.
            dna_reg <= {DIN, dna_reg[56:1]};
        end
    end
endmodule
