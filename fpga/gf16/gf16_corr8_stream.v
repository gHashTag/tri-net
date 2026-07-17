// gf16_corr8_stream -- streaming 8-tap GF16 matched-filter demodulator core.
//
// This is the PL-side core of the radio modem: one GF16 sample enters per
// clock (s_valid/s_data), and the running correlation of the last 8 samples
// against 8 reference taps leaves one clock later (m_valid/m_data). The taps
// are loaded once through a small write port (c_wr/c_addr/c_data) -- in a real
// PL image that port is an AXI-Lite config register bank driven by the PS.
//
// Two things this shape buys over the bare gf16_corr8:
//   1. IO footprint is a handful of pins (a stream + a config port), not the
//      272 parallel pins of the flat correlator -- so it actually places on the
//      xc7z020clg400 (125 IO) that carries the AD9361.
//   2. The taps are RUNTIME registers, not compile-time constants, so the eight
//      GF16 multipliers are real variable*variable multipliers. A resource
//      report on this module is the honest cost of the modem core; constant
//      taps would let yosys fold the multipliers away and lie about the budget.
//
// Internal signal names are prefixed (xr*, tp*) so they cannot collide with the
// gf16_corr8 instance's own port names (x0..x7, h0..h7). A same-name reg on a
// named port connection (.h0(h0)) confuses scope resolution and silently drops
// the register's writes -- verified as X on the even taps until renamed.
//
// SSOT for the numeric format: t27/specs/numeric/gf16.t27.
module gf16_corr8_stream (
    input  wire        clk,
    input  wire        rst,
    // sample stream (GF16), newest sample on s_data when s_valid
    input  wire        s_valid,
    input  wire [15:0] s_data,
    // coefficient load port: write tap tp[c_addr] <= c_data
    input  wire        c_wr,
    input  wire [2:0]  c_addr,
    input  wire [15:0] c_data,
    // correlation result (GF16), one cycle after each accepted sample
    output reg         m_valid,
    output reg  [15:0] m_data
);
    // reference taps tp0..tp7 (loaded via the config port)
    reg [15:0] tp0, tp1, tp2, tp3, tp4, tp5, tp6, tp7;
    always @(posedge clk) begin
        if (c_wr) begin
            case (c_addr)
                3'd0: tp0 <= c_data;
                3'd1: tp1 <= c_data;
                3'd2: tp2 <= c_data;
                3'd3: tp3 <= c_data;
                3'd4: tp4 <= c_data;
                3'd5: tp5 <= c_data;
                3'd6: tp6 <= c_data;
                3'd7: tp7 <= c_data;
            endcase
        end
    end

    // sample shift register: xr0 is newest, xr7 is 7 samples ago
    reg [15:0] xr0, xr1, xr2, xr3, xr4, xr5, xr6, xr7;
    always @(posedge clk) begin
        if (rst) begin
            xr0 <= 16'h0000; xr1 <= 16'h0000; xr2 <= 16'h0000; xr3 <= 16'h0000;
            xr4 <= 16'h0000; xr5 <= 16'h0000; xr6 <= 16'h0000; xr7 <= 16'h0000;
        end else if (s_valid) begin
            xr7 <= xr6; xr6 <= xr5; xr5 <= xr4; xr4 <= xr3;
            xr3 <= xr2; xr2 <= xr1; xr1 <= xr0; xr0 <= s_data;
        end
    end

    // combinational correlator over the current window
    wire [15:0] corr;
    gf16_corr8 u_corr (
        .x0(xr0), .x1(xr1), .x2(xr2), .x3(xr3),
        .x4(xr4), .x5(xr5), .x6(xr6), .x7(xr7),
        .h0(tp0), .h1(tp1), .h2(tp2), .h3(tp3),
        .h4(tp4), .h5(tp5), .h6(tp6), .h7(tp7),
        .corr(corr)
    );

    // register the output so the core is a clean pipeline stage
    always @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_data  <= 16'h0000;
        end else begin
            m_valid <= s_valid;
            m_data  <= corr;
        end
    end
endmodule
