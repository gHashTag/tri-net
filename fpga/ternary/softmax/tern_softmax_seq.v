`default_nettype none

// tern_softmax_seq -- the same fixed-point softmax as tern_softmax, but with ONE
// shared divider used over N cycles instead of N parallel combinational dividers.
// The combinational version cost ~28k LUT for N=8 (eight dividers, ~half the
// xc7z020); sharing one divider trades N-cycle latency for ~1/N the area. Still
// zero DSP (ROM exp + LUT-mapped divide).
//
// FSM: IDLE -> PREP (max, exp via ROM, sum) -> DIV (one p_i per cycle) -> DONE
//
// SSOT: t27/specs/igla/coder/arch.t27.
module tern_softmax_seq #(
    parameter integer N    = 8,
    parameter integer LOGW = 12,
    parameter integer PW   = 17
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     start,
    input  wire signed [N*LOGW-1:0] x,
    output reg                      done,
    output reg  [N*PW-1:0]          prob
);
    reg [15:0] lut [0:127];
    initial $readmemh("exp_lut.hex", lut);

    localparam [1:0] S_IDLE=0, S_PREP=1, S_DIV=2, S_DONE=3;
    reg [1:0] st;
    integer i;
    reg signed [LOGW-1:0] xi, mx;
    reg [15:0] e [0:N-1];
    reg [31:0] sum;
    reg [$clog2(N):0] idx;

    always @(posedge clk) begin
        if (rst) begin st<=S_IDLE; done<=1'b0; prob<=0; sum<=0; idx<=0; end
        else begin
            case (st)
                S_IDLE: begin done<=1'b0; if (start) st<=S_PREP; end
                S_PREP: begin
                    // max
                    mx = x[0 +: LOGW];
                    for (i=1;i<N;i=i+1) begin xi=x[i*LOGW +: LOGW]; if (xi>mx) mx=xi; end
                    // exp(x_i - max) from ROM, and the running sum
                    sum = 32'd0;
                    for (i=0;i<N;i=i+1) begin
                        xi = x[i*LOGW +: LOGW];
                        e[i] = lut[(mx - xi > 127) ? 8'd127 : (mx - xi)];
                        sum = sum + e[i];
                    end
                    idx <= 0; st <= S_DIV;
                end
                S_DIV: begin                       // one shared divide per cycle
                    prob[idx*PW +: PW] <= ({e[idx], 16'd0}) / sum;
                    if (idx == N-1) st <= S_DONE;
                    idx <= idx + 1;
                end
                S_DONE: begin done <= 1'b1; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
