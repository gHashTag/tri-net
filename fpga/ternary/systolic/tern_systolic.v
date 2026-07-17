`default_nettype none

// tern_systolic -- parametric K x N weight-stationary ternary systolic array
// (IGLA-RACE systolic_ternary). Computes y[n] = sum_k x[k] * W[k][n] with the
// weights W (K x N ternary codes) stationary in the PEs. Activations x[k] enter
// row k skewed by k cycles (internal skew chain); partial sums accumulate down
// each column; column n's result leaves PE[K-1][n] at time K + n (diagonal
// wavefront). N*K sign-select MACs per cycle, ZERO DSP.
//
// Weights load in parallel via w_load + w_all (a real array shifts them in;
// parallel load is functionally identical and keeps the harness simple).
//
// SSOT: t27/specs/igla/race/systolic_ternary.t27.
module tern_systolic #(
    parameter integer K   = 4,   // contraction dim (rows)
    parameter integer N   = 4,   // output dim (cols)
    parameter integer W   = 8,
    parameter integer ACC = 24
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                w_load,
    input  wire [K*N*2-1:0]    w_all,     // W[k][n] at bit (k*N+n)*2
    input  wire                x_valid,   // pulse to inject one x vector
    input  wire [K*W-1:0]      x_vec,     // x[k] at bit k*W
    output wire [N*ACC-1:0]    y_col      // y[n] at bit n*ACC (skewed by column)
);
    genvar k, n, d;

    // ---- per-row skew: row k activation is delayed by k cycles ----
    // sk[k] holds the (possibly delayed) activation entering row k this cycle.
    wire signed [W-1:0] row_a [0:K-1];
    generate
        for (k = 0; k < K; k = k + 1) begin : g_skew
            if (k == 0) begin : d0
                assign row_a[0] = x_valid ? x_vec[0 +: W] : {W{1'b0}};
            end else begin : dn
                // shift register of depth k, fed by x_vec[k] gated on x_valid
                reg signed [W-1:0] sr [0:k-1];
                integer j;
                always @(posedge clk) begin
                    if (rst) begin for (j=0;j<k;j=j+1) sr[j] <= 0; end
                    else begin
                        sr[0] <= x_valid ? x_vec[k*W +: W] : {W{1'b0}};
                        for (j=1;j<k;j=j+1) sr[j] <= sr[j-1];
                    end
                end
                assign row_a[k] = sr[k-1];
            end
        end
    endgenerate

    // ---- PE grid ----
    // a_h[k][n] : activation entering PE[k][n] from the left (n=0 is row_a[k])
    // p_v[k][n] : partial sum entering PE[k][n] from above (k=0 is zero)
    wire signed [W-1:0]   a_h [0:K-1][0:N];
    wire signed [ACC-1:0] p_v [0:K][0:N-1];
    generate
        for (k = 0; k < K; k = k + 1) begin : g_arow
            assign a_h[k][0] = row_a[k];
        end
        for (n = 0; n < N; n = n + 1) begin : g_pcol
            assign p_v[0][n] = {ACC{1'b0}};
        end
        for (k = 0; k < K; k = k + 1) begin : g_r
            for (n = 0; n < N; n = n + 1) begin : g_c
                tern_pe #(.W(W), .ACC(ACC)) pe (
                    .clk(clk), .rst(rst),
                    .w_load(w_load), .w_in(w_all[(k*N+n)*2 +: 2]),
                    .a_in(a_h[k][n]), .psum_in(p_v[k][n]),
                    .a_out(a_h[k][n+1]), .psum_out(p_v[k+1][n])
                );
            end
        end
        for (n = 0; n < N; n = n + 1) begin : g_y
            assign y_col[n*ACC +: ACC] = p_v[K][n];
        end
    endgenerate
endmodule

`default_nettype wire
