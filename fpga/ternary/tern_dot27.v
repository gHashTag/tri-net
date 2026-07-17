`default_nettype none

// tern_dot27 -- ZeroDSP K-wide ternary dot product (the edge-AI MAC primitive).
//
// One vector of K ternary weights {-1,0,+1} times K signed activations,
// accumulated. Ternary weights make each product a sign-select, so the whole
// dot product is a signed ADDER TREE: zero DSP. The terms are summed by an
// explicit BALANCED binary tree (depth ceil(log2 K), not a K-long chain), which
// is what lifts the Fmax of every consumer (tern_matvec, tern_mlp) -- the C3
// balanced-tree fix, generalised to any K and made synthesizable with a flat
// node array (constant generate bounds; a data-dependent while-loop does not
// synthesize). Weight code: 2'b01=+1, 2'b10=-1, else 0.
//
// SSOT: t27/specs/numeric/tf3.t27, t27/specs/igla/race/ternary_mac.t27.
module tern_dot27 #(
    parameter integer K   = 27,   // trits / activations per dot
    parameter integer W   = 8,    // signed activation width (int8)
    parameter integer ACC = 16    // accumulator width
) (
    input  wire [K*W-1:0]        act,   // K packed signed activations
    input  wire [K*2-1:0]        wts,   // K packed ternary weights
    output wire signed [ACC-1:0] dot
);
    localparam integer LEV = (K <= 1) ? 1 : $clog2(K);
    localparam integer P   = 1 << LEV;         // padded leaf count (power of two)

    // flat binary tree: node[1] is the root; node[i] children are 2i and 2i+1;
    // leaves live at node[P .. 2P-1].
    wire signed [ACC-1:0] node [1:2*P-1];
    genvar g;
    generate
        // leaves: sign-selected terms (0 for padding beyond K)
        for (g = 0; g < P; g = g + 1) begin : g_leaf
            if (g < K) begin : real_leaf
                wire signed [ACC-1:0] ax = {{(ACC-W){act[g*W+W-1]}}, act[g*W +: W]};
                assign node[P+g] = (wts[g*2 +: 2] == 2'b01) ?  ax :
                                   (wts[g*2 +: 2] == 2'b10) ? -ax :
                                                               {ACC{1'b0}};
            end else begin : pad_leaf
                assign node[P+g] = {ACC{1'b0}};
            end
        end
        // internal nodes: balanced pairwise sums
        for (g = 1; g < P; g = g + 1) begin : g_node
            assign node[g] = node[2*g] + node[2*g+1];
        end
    endgenerate

    assign dot = node[1];
endmodule

`default_nettype wire
