`default_nettype none

// tern_matvec -- a ternary NN layer: M output neurons, each a K-wide ternary dot
// product over a shared activation vector. This is a BitNet-class fully-connected
// layer in hardware, ZERO DSP -- M parallel tern_dot27 engines. The weight matrix
// is M*K ternary trits (2 bits each); the activation vector is K signed ints.
//
// SSOT: t27/specs/fpga/mac.t27, t27/specs/numeric/tf3.t27.
module tern_matvec #(
    parameter integer M   = 4,    // output neurons
    parameter integer K   = 27,   // inputs per neuron
    parameter integer W   = 8,
    parameter integer ACC = 16
) (
    input  wire [K*W-1:0]     act,   // shared activation vector
    input  wire [M*K*2-1:0]   wts,   // M weight rows, K ternary trits each
    output wire [M*ACC-1:0]   out    // M packed signed neuron outputs
);
    genvar m;
    generate
        for (m = 0; m < M; m = m + 1) begin : neuron
            tern_dot27 #(.K(K), .W(W), .ACC(ACC)) u_dot (
                .act(act),
                .wts(wts[m*K*2 +: K*2]),
                .dot(out[m*ACC +: ACC])
            );
        end
    endgenerate
endmodule

`default_nettype wire
