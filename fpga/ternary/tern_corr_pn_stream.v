`default_nettype none

// tern_corr_pn_stream -- streaming N-tap ZeroDSP PN despreader with a narrow IO
// footprint so it place-and-routes on the xc7z020 (the packed combinational
// tern_corr_pn has N*W + N*2 pins and cannot). One signed chip-sample enters per
// clock; the running correlation against the N loaded ternary taps leaves one
// clock later. Taps load through a config port (c_wr/c_addr/c_data). Same
// sign-select adder tree inside -- zero DSP.
//
// SSOT for the ternary format: t27/specs/numeric/gfternary.t27.
module tern_corr_pn_stream #(
    parameter integer N    = 63,
    parameter integer W    = 16,
    parameter integer ACC  = 24,
    parameter integer AW   = 6     // ceil(log2(N)) address bits
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              s_valid,
    input  wire signed [W-1:0] s_data,
    input  wire              c_wr,
    input  wire [AW-1:0]     c_addr,
    input  wire [1:0]        c_data,
    output reg               m_valid,
    output reg signed [ACC-1:0] m_data
);
    // ternary taps (2-bit each), loaded by address
    reg [1:0] tp [0:N-1];
    always @(posedge clk) begin
        if (c_wr) tp[c_addr] <= c_data;
    end

    // N-deep signed sample shift register (xr[0] newest)
    reg signed [W-1:0] xr [0:N-1];
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N; i = i + 1) xr[i] <= 0;
        end else if (s_valid) begin
            for (i = N-1; i > 0; i = i - 1) xr[i] <= xr[i-1];
            xr[0] <= s_data;
        end
    end

    // combinational sign-select correlation over the window
    reg signed [ACC-1:0] acc;
    reg signed [W-1:0]   xi;
    always @(*) begin
        acc = {ACC{1'b0}};
        for (i = 0; i < N; i = i + 1) begin
            xi = xr[i];
            case (tp[i])
                2'b01: acc = acc + {{(ACC-W){xi[W-1]}}, xi};
                2'b10: acc = acc - {{(ACC-W){xi[W-1]}}, xi};
                default: acc = acc;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_data  <= 0;
        end else begin
            m_valid <= s_valid;
            m_data  <= acc;
        end
    end
endmodule

`default_nettype wire
