`default_nettype none

// tern_corr8_stream -- streaming ZeroDSP ternary matched-filter demod core.
//
// One signed sample enters per clock (s_valid/s_data); the correlation of the
// last 8 samples against 8 ternary taps leaves one clock later. Taps are 2 bits
// each (the whole reference code is 16 bits) and load through a small config
// port (an AXI-Lite register in a real PL image). No DSP, no float -- just a
// shift register and a signed adder tree. Compare with gf16_corr8_stream, which
// does the same job with 8 DSP48E1 and a float normalization tree.
//
// SSOT for the ternary format: t27/specs/numeric/{tf3,gfternary}.t27.
module tern_corr8_stream #(
    parameter integer W   = 16,
    parameter integer ACC = 20
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              s_valid,
    input  wire signed [W-1:0] s_data,
    // ternary tap load port: write tap tp[c_addr] <= c_data (2-bit code)
    input  wire              c_wr,
    input  wire        [2:0] c_addr,
    input  wire        [1:0] c_data,
    output reg               m_valid,
    output reg signed [ACC-1:0] m_data
);
    // ternary taps tp0..tp7 (2-bit codes), loaded via config port
    reg [1:0] tp0, tp1, tp2, tp3, tp4, tp5, tp6, tp7;
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

    // signed sample shift register: xr0 newest, xr7 seven samples ago
    reg signed [W-1:0] xr0, xr1, xr2, xr3, xr4, xr5, xr6, xr7;
    always @(posedge clk) begin
        if (rst) begin
            xr0 <= 0; xr1 <= 0; xr2 <= 0; xr3 <= 0;
            xr4 <= 0; xr5 <= 0; xr6 <= 0; xr7 <= 0;
        end else if (s_valid) begin
            xr7 <= xr6; xr6 <= xr5; xr5 <= xr4; xr4 <= xr3;
            xr3 <= xr2; xr2 <= xr1; xr1 <= xr0; xr0 <= s_data;
        end
    end

    wire signed [ACC-1:0] corr;
    tern_corr8 #(.W(W), .ACC(ACC)) u_corr (
        .x0(xr0), .x1(xr1), .x2(xr2), .x3(xr3),
        .x4(xr4), .x5(xr5), .x6(xr6), .x7(xr7),
        .w0(tp0), .w1(tp1), .w2(tp2), .w3(tp3),
        .w4(tp4), .w5(tp5), .w6(tp6), .w7(tp7),
        .corr(corr)
    );

    always @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_data  <= 0;
        end else begin
            m_valid <= s_valid;
            m_data  <= corr;
        end
    end
endmodule

`default_nettype wire
