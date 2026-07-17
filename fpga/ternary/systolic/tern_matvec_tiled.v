`default_nettype none

// tern_matvec_tiled -- run a layer LARGER than the physical engine by tiling the
// output (neuron) dimension: one fixed tern_matvec of MT neurons is reused over
// M/MT tiles, its weights streamed from a BRAM each tile. This is how a modest
// array runs a real IGLA-Coder layer (M up to thousands) -- the same way every
// systolic NPU tiles a big matmul through a fixed PE array. Weights live in a
// dual-use memory (here a reg array, a BRAM in silicon); the activation vector is
// held for all tiles. Zero DSP (the inner MAC is the balanced-tree tern_dot27).
//
// FSM: IDLE -> RUN (one tile/cycle, MT neuron outputs each) -> DONE.
//
// SSOT: t27/specs/igla/race/bram_weights.t27, systolic_ternary.t27.
module tern_matvec_tiled #(
    parameter integer M   = 32,   // total neurons (output dim)
    parameter integer K   = 27,   // inputs per neuron
    parameter integer MT  = 4,    // physical tile size (neurons/tile)
    parameter integer W   = 8,
    parameter integer ACC = 16
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                start,
    input  wire [K*W-1:0]      x,          // activation vector (held)
    input  wire [M*K*2-1:0]    w_all,      // full weight matrix (BRAM image)
    output reg                 done,
    output reg  [M*ACC-1:0]    y           // full output vector
);
    localparam integer TILES = (M + MT - 1) / MT;

    // weight memory (BRAM in silicon): row m at w_mem[m]
    reg [K*2-1:0] w_mem [0:M-1];
    integer i;
    // load the BRAM image once (a real design streams this from DDR)
    always @(posedge clk) if (rst) for (i=0;i<M;i=i+1) w_mem[i] <= w_all[i*K*2 +: K*2];

    // the one physical tile: MT neurons wide
    reg  [MT*K*2-1:0] wt;
    wire [MT*ACC-1:0] yt;
    genvar g;
    generate
        for (g = 0; g < MT; g = g + 1) begin : g_pe
            tern_dot27 #(.K(K), .W(W), .ACC(ACC)) dot (
                .act(x), .wts(wt[g*K*2 +: K*2]), .dot(yt[g*ACC +: ACC]));
        end
    endgenerate

    reg [1:0] st;
    localparam [1:0] S_IDLE=0, S_RUN=1, S_DONE=2;
    reg [$clog2(TILES+1):0] t;
    integer j;

    always @(posedge clk) begin
        if (rst) begin st<=S_IDLE; done<=1'b0; t<=0; y<=0; wt<=0; end
        else begin
            case (st)
                S_IDLE: begin done<=1'b0; if (start) begin t<=0; st<=S_RUN;
                                // preload tile 0 weights
                                for (j=0;j<MT;j=j+1) wt[j*K*2 +: K*2] <= w_mem[j];
                              end end
                S_RUN: begin
                    // store this tile's MT neuron outputs
                    for (j=0;j<MT;j=j+1)
                        if (t*MT + j < M)
                            y[(t*MT+j)*ACC +: ACC] <= yt[j*ACC +: ACC];
                    // fetch next tile's weights from BRAM
                    for (j=0;j<MT;j=j+1)
                        wt[j*K*2 +: K*2] <= w_mem[(t+1)*MT + j];
                    if (t == TILES-1) st <= S_DONE;
                    t <= t + 1;
                end
                S_DONE: begin done<=1'b1; st<=S_IDLE; end
                default: st<=S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
