`default_nettype none

// tern_pe -- weight-stationary ternary systolic processing element (IGLA-RACE
// systolic_ternary). The activation passes to the right; the partial sum
// accumulates downward; the ternary weight is stationary (loaded once). The
// multiply is a sign-select, so the whole array is zero-DSP.
//
//   a_out    = a_in                         (registered pass-through, ->right)
//   psum_out = psum_in + (a_in * w)         (registered accumulate,   ->down)
//
// SSOT: t27/specs/igla/race/systolic_ternary.t27, ternary_mac.t27.
module tern_pe #(
    parameter integer W = 8, parameter integer ACC = 24
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  w_load,
    input  wire        [1:0]     w_in,        // ternary weight to latch
    input  wire signed [W-1:0]   a_in,
    input  wire signed [ACC-1:0] psum_in,
    output reg  signed [W-1:0]   a_out,
    output reg  signed [ACC-1:0] psum_out
);
    reg [1:0] w;
    always @(posedge clk) if (w_load) w <= w_in;

    wire signed [ACC-1:0] ax = {{(ACC-W){a_in[W-1]}}, a_in};
    wire signed [ACC-1:0] prod = (w == 2'b01) ?  ax :
                                 (w == 2'b10) ? -ax :
                                                 {ACC{1'b0}};
    always @(posedge clk) begin
        if (rst) begin a_out <= 0; psum_out <= 0; end
        else begin a_out <= a_in; psum_out <= psum_in + prod; end
    end
endmodule

`default_nettype wire
