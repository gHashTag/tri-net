`default_nettype none

// tern_mlp -- a clocked, end-to-end 2-layer ternary MLP inference engine.
//
// This is the IGLA-RACE `ternary_inference` flow (weights -> ternary GEMM ->
// result) built from our verified `tern_matvec` PE: it runs a WHOLE network in
// one cycle-accurate simulation, not layer-by-layer, and reports the class plus
// the cycle count. Zero DSP. The requantization between layers (ReLU + >>2,
// clip to int8) is the step the PS does in a real BitNet accelerator; here it is
// one registered stage so the whole forward pass is self-contained hardware.
//
// FSM:  IDLE -> L1 (register layer-1 dot products) -> RQ (requant to int8)
//            -> L2 (register layer-2 dot products) -> ARGMAX -> DONE
//
// SSOT for the ternary format: t27/specs/numeric/gfternary.t27,
// t27/specs/igla/race/ternary_inference.t27.
module tern_mlp #(
    parameter integer K1  = 27, parameter integer M1 = 16,   // layer 1: M1 x K1
    parameter integer K2  = 16, parameter integer M2 = 3,    // layer 2: M2 x K2
    parameter integer W   = 8,  parameter integer ACC = 16
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                start,
    input  wire [K1*W-1:0]     x,        // int8 feature vector
    input  wire [M1*K1*2-1:0]  w1,       // layer-1 ternary weights
    input  wire [M2*K2*2-1:0]  w2,       // layer-2 ternary weights
    output reg                 done,
    output reg  [1:0]          class_id, // argmax(layer 2)
    output reg  signed [ACC-1:0] y0, y1, y2,
    output reg  [7:0]          cycles
);
    localparam [2:0] S_IDLE=0, S_L1=1, S_RQ=2, S_L2=3, S_ARG=4, S_DONE=5;
    reg [2:0] st;

    // layer-1 GEMM (combinational, zero DSP)
    wire [M1*ACC-1:0] l1_out;
    tern_matvec #(.M(M1), .K(K1), .W(W), .ACC(ACC)) mv1 (.act(x),  .wts(w1), .out(l1_out));

    // registered layer-1 result, and the requantized int8 hidden activations
    reg signed [ACC-1:0] a1 [0:M1-1];
    reg [K2*W-1:0] h;                 // int8 hidden vector feeding layer 2
    integer i;
    reg signed [ACC-1:0] tmp;
    reg signed [ACC-1:0] hq;

    // layer-2 GEMM over the requantized hidden vector
    wire [M2*ACC-1:0] l2_out;
    tern_matvec #(.M(M2), .K(K2), .W(W), .ACC(ACC)) mv2 (.act(h), .wts(w2), .out(l2_out));

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; done <= 1'b0; cycles <= 8'd0; class_id <= 2'd0;
            y0 <= 0; y1 <= 0; y2 <= 0; h <= 0;
        end else begin
            case (st)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin cycles <= 8'd0; st <= S_L1; end
                end
                S_L1: begin                       // capture layer-1 dot products
                    for (i=0;i<M1;i=i+1) a1[i] <= $signed(l1_out[i*ACC +: ACC]);
                    cycles <= cycles + 8'd1; st <= S_RQ;
                end
                S_RQ: begin                       // requant: ReLU, >>2, clip [0,127]
                    for (i=0;i<M1 && i<K2;i=i+1) begin
                        tmp = a1[i];
                        hq  = (tmp < 0) ? 0 : (tmp >>> 2);
                        if (hq > 127) hq = 127;
                        h[i*W +: W] <= hq[W-1:0];
                    end
                    cycles <= cycles + 8'd1; st <= S_L2;
                end
                S_L2: begin                       // capture layer-2 dot products
                    y0 <= $signed(l2_out[0*ACC +: ACC]);
                    y1 <= $signed(l2_out[1*ACC +: ACC]);
                    y2 <= $signed(l2_out[2*ACC +: ACC]);
                    cycles <= cycles + 8'd1; st <= S_ARG;
                end
                S_ARG: begin                      // argmax of the 3 outputs
                    if (y0 >= y1 && y0 >= y2)      class_id <= 2'd0;
                    else if (y1 >= y2)             class_id <= 2'd1;
                    else                          class_id <= 2'd2;
                    cycles <= cycles + 8'd1; st <= S_DONE;
                end
                S_DONE: begin done <= 1'b1; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
