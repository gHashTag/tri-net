`default_nettype none

// tern_dot27 -- ZeroDSP 27-wide ternary dot product (the edge-AI MAC primitive).
//
// One 27-trit TernaryWord of weights (t27/specs/fpga/mac.t27: MAC_WIDTH = 27)
// times a vector of 27 signed activations, accumulated. Because the weights are
// ternary {-1,0,+1} the products are sign-selects, so a whole BitNet-class dot
// product is a signed adder tree: ZERO DSP. This is the same op the radio
// despreader runs, pointed at neural-net inference instead of a matched filter
// -- the ternary MAC is one primitive serving both the mesh's PHY and its
// on-board AI. Weight code: 2'b01=+1, 2'b10=-1, else 0.
//
// SSOT for the format: t27/specs/numeric/tf3.t27 (ternary weights),
// t27/specs/fpga/mac.t27 (the 27-trit ZeroDSP MAC).
module tern_dot27 #(
    parameter integer K   = 27,   // trits / activations per dot
    parameter integer W   = 8,    // signed activation width (int8)
    parameter integer ACC = 16    // accumulator width
) (
    input  wire [K*W-1:0]        act,   // K packed signed activations
    input  wire [K*2-1:0]        wts,   // K packed ternary weights
    output wire signed [ACC-1:0] dot
);
    integer i;
    reg signed [ACC-1:0] acc;
    reg signed [W-1:0]   ai;
    reg        [1:0]     wi;

    always @(*) begin
        acc = {ACC{1'b0}};
        for (i = 0; i < K; i = i + 1) begin
            ai = act[i*W +: W];
            wi = wts[i*2 +: 2];
            case (wi)
                2'b01: acc = acc + {{(ACC-W){ai[W-1]}}, ai};
                2'b10: acc = acc - {{(ACC-W){ai[W-1]}}, ai};
                default: acc = acc;
            endcase
        end
    end

    assign dot = acc;
endmodule

`default_nettype wire
