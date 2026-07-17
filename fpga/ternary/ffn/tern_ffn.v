`default_nettype none

// tern_ffn -- a ternary transformer FEED-FORWARD sublayer in hardware:
//   y = x + W2 . ReLU(W1 . x)
// the up-projection W1 (H x D), down-projection W2 (D x H), and residual add,
// all ternary and multiplier-free (tree tern_matvec). This is the IGLA-Coder
// FFN block -- the activation and residual live in the FSM, not the PS, so the
// whole sublayer is self-contained hardware. Zero DSP.
//
// FSM: IDLE -> L1 -> RQ (ReLU + >>S1 to int8) -> L2 -> RES (x + a2>>S2) -> DONE
//
// SSOT: t27/specs/igla/coder/arch.t27 (D_FF), igla/race/ternary_gemm.t27.
module tern_ffn #(
    parameter integer D   = 64,  parameter integer H = 256,
    parameter integer W   = 8,   parameter integer ACC = 24,
    parameter integer S1  = 4,   parameter integer S2 = 4
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                start,
    input  wire [D*W-1:0]      x,
    input  wire [H*D*2-1:0]    w1,        // up-projection weights
    input  wire [D*H*2-1:0]    w2,        // down-projection weights
    output reg                 done,
    output reg  [D*ACC-1:0]      y_flat,
    output reg  [7:0]          cycles
);
    localparam [2:0] S_IDLE=0, S_L1=1, S_RQ=2, S_L2=3, S_RES=4, S_DONE=5;
    reg [2:0] st;
    integer i;

    // up-projection W1 . x  (H outputs)
    wire [H*ACC-1:0] l1_out;
    tern_matvec #(.M(H), .K(D), .W(W), .ACC(ACC)) mv1 (.act(x), .wts(w1), .out(l1_out));

    // requantized hidden vector (int8) feeding the down-projection
    reg [H*W-1:0] h;
    reg signed [ACC-1:0] a1i, hq;

    // down-projection W2 . h  (D outputs)
    wire [D*ACC-1:0] l2_out;
    tern_matvec #(.M(D), .K(H), .W(W), .ACC(ACC)) mv2 (.act(h), .wts(w2), .out(l2_out));

    reg signed [ACC-1:0] a2i, xi;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; done <= 1'b0; cycles <= 8'd0; h <= 0;
            y_flat <= 0;
        end else begin
            case (st)
                S_IDLE: begin done<=1'b0; if (start) begin cycles<=8'd0; st<=S_L1; end end
                S_L1: begin cycles<=cycles+8'd1; st<=S_RQ; end   // l1_out settles combinationally
                S_RQ: begin
                    for (i=0;i<H;i=i+1) begin
                        a1i = $signed(l1_out[i*ACC +: ACC]);
                        hq  = (a1i < 0) ? 0 : (a1i >>> S1);
                        if (hq > 127) hq = 127;
                        h[i*W +: W] <= hq[W-1:0];
                    end
                    cycles<=cycles+8'd1; st<=S_L2;
                end
                S_L2: begin cycles<=cycles+8'd1; st<=S_RES; end
                S_RES: begin
                    for (i=0;i<D;i=i+1) begin
                        a2i = $signed(l2_out[i*ACC +: ACC]);
                        xi  = $signed({{(ACC-W){x[i*W+W-1]}}, x[i*W +: W]});
                        y_flat[i*ACC +: ACC] <= xi + (a2i >>> S2);
                    end
                    cycles<=cycles+8'd1; st<=S_DONE;
                end
                S_DONE: begin done<=1'b1; st<=S_IDLE; end
                default: st<=S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
