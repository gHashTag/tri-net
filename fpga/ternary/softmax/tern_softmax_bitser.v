`default_nettype none

// tern_softmax_bitser -- same fixed-point softmax, normalised by ONE bit-serial
// restoring divider (one subtractor, 32 cycles per quotient) shared over the N
// values. The combinational version cost ~28k LUT and the one-shared-`/` version
// ~14k; a restoring divider is a handful of registers plus one subtract, so this
// drops to a few hundred LUT -- at the cost of ~N*32 cycles of latency. Still
// zero DSP, still bit-exact. A reciprocal-multiply would be smaller in cycles
// but needs a multiplier (DSP); the whole point is to stay multiplier-free.
//
// SSOT: t27/specs/igla/coder/arch.t27.
module tern_softmax_bitser #(
    parameter integer N    = 8,
    parameter integer LOGW = 12,
    parameter integer PW   = 17,
    parameter integer DW   = 32   // dividend width (e_i << 16)
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
    // restoring-divider state
    reg [DW-1:0]  dividend, quo;
    reg [DW:0]    rem;
    reg [5:0]     bitcnt;
    wire [DW:0]   shifted = {rem[DW-1:0], dividend[DW-1]};
    wire          ge      = (shifted >= {1'b0, sum});

    always @(posedge clk) begin
        if (rst) begin st<=S_IDLE; done<=1'b0; prob<=0; sum<=0; idx<=0; end
        else begin
            case (st)
                S_IDLE: begin done<=1'b0; if (start) st<=S_PREP; end
                S_PREP: begin
                    mx = x[0 +: LOGW];
                    for (i=1;i<N;i=i+1) begin xi=x[i*LOGW +: LOGW]; if (xi>mx) mx=xi; end
                    sum = 32'd0;
                    for (i=0;i<N;i=i+1) begin
                        xi = x[i*LOGW +: LOGW];
                        e[i] = lut[(mx - xi > 127) ? 8'd127 : (mx - xi)];
                        sum = sum + e[i];
                    end
                    idx <= 0;
                    dividend <= {e[0], 16'd0}; rem <= 0; quo <= 0; bitcnt <= 6'd32;
                    st <= S_DIV;
                end
                S_DIV: begin
                    // one restoring step
                    rem      <= ge ? (shifted - {1'b0, sum}) : shifted;
                    quo      <= {quo[DW-2:0], ge};
                    dividend <= {dividend[DW-2:0], 1'b0};
                    if (bitcnt == 6'd1) begin
                        // quotient ready (this cycle's ge is its LSB)
                        prob[idx*PW +: PW] <= {quo[PW-2:0], ge};
                        if (idx == N-1) st <= S_DONE;
                        else begin
                            idx <= idx + 1;
                            dividend <= {e[idx+1], 16'd0}; rem <= 0; quo <= 0; bitcnt <= 6'd32;
                        end
                    end else bitcnt <= bitcnt - 6'd1;
                end
                S_DONE: begin done <= 1'b1; st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
