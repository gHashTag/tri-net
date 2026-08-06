`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul64_stream -- byte-stream protocol core for the GF-T64 multiplier.
// GF-T64 operands are 79-bit (15-bit offset + 64-bit mantissa), carried as offset
// (2 bytes LE) + mantissa (8 bytes LE). Assembles one frame, folds it through
// gft_mul64 (256-bit significand datapath), emits offset (2B) + mantissa (8B).
//
//   frame: [0xAA][0x55][a_off:2][a_mant:8][b_off:2][b_mant:8][cmd]
//   emit : out_valid pulse with out_off (16b used) + out_mant (64b)
// Tested at the byte level (no UART baud) via gft_mul64_stream_tb.
// ============================================================================
module gft_mul64_stream (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_new,
    input  wire [7:0]  rx_byte,
    output reg         out_valid,
    output reg  [15:0] out_off,
    output reg  [63:0] out_mant
);
    reg [4:0]  frm;
    reg [15:0] a_off, b_off;
    reg [63:0] a_mant, b_mant;
    reg        fold;

    always @(posedge clk or posedge rst) begin
        if (rst) begin frm<=0; a_off<=0; b_off<=0; a_mant<=0; b_mant<=0; fold<=0; end
        else begin
            fold <= 1'b0;
            if (rx_new) begin
                case (frm)
                    5'd0:  frm <= (rx_byte==8'hAA) ? 5'd1 : 5'd0;
                    5'd1:  frm <= (rx_byte==8'h55) ? 5'd2 : 5'd0;
                    5'd2:  begin a_off[7:0]    <= rx_byte; frm <= 5'd3;  end
                    5'd3:  begin a_off[15:8]   <= rx_byte; frm <= 5'd4;  end
                    5'd4:  begin a_mant[7:0]   <= rx_byte; frm <= 5'd5;  end
                    5'd5:  begin a_mant[15:8]  <= rx_byte; frm <= 5'd6;  end
                    5'd6:  begin a_mant[23:16] <= rx_byte; frm <= 5'd7;  end
                    5'd7:  begin a_mant[31:24] <= rx_byte; frm <= 5'd8;  end
                    5'd8:  begin a_mant[39:32] <= rx_byte; frm <= 5'd9;  end
                    5'd9:  begin a_mant[47:40] <= rx_byte; frm <= 5'd10; end
                    5'd10: begin a_mant[55:48] <= rx_byte; frm <= 5'd11; end
                    5'd11: begin a_mant[63:56] <= rx_byte; frm <= 5'd12; end
                    5'd12: begin b_off[7:0]    <= rx_byte; frm <= 5'd13; end
                    5'd13: begin b_off[15:8]   <= rx_byte; frm <= 5'd14; end
                    5'd14: begin b_mant[7:0]   <= rx_byte; frm <= 5'd15; end
                    5'd15: begin b_mant[15:8]  <= rx_byte; frm <= 5'd16; end
                    5'd16: begin b_mant[23:16] <= rx_byte; frm <= 5'd17; end
                    5'd17: begin b_mant[31:24] <= rx_byte; frm <= 5'd18; end
                    5'd18: begin b_mant[39:32] <= rx_byte; frm <= 5'd19; end
                    5'd19: begin b_mant[47:40] <= rx_byte; frm <= 5'd20; end
                    5'd20: begin b_mant[55:48] <= rx_byte; frm <= 5'd21; end
                    5'd21: begin b_mant[63:56] <= rx_byte; frm <= 5'd22; end
                    5'd22: begin fold <= 1'b1; frm <= 5'd0; end
                    default: frm <= 5'd0;
                endcase
            end
        end
    end

    // Combinational GF-T64 multiply on the latched operands.
    wire [31:0] o_off;
    wire [63:0] o_mant;
    gft_mul64 #(.BIAS(32'd9841), .OFFSET_MAX(32'd19682), .MANT_ONE(128'h1_0000_0000_0000_0000)) u_mul (
        .a_off({16'd0, a_off}), .a_mant(a_mant),
        .b_off({16'd0, b_off}), .b_mant(b_mant),
        .out_off(o_off), .out_mant(o_mant));

    // Register + emit one cycle after fold.
    always @(posedge clk or posedge rst) begin
        if (rst) begin out_valid<=0; out_off<=0; out_mant<=0; end
        else begin
            out_valid <= fold;
            if (fold) begin out_off <= o_off[15:0]; out_mant <= o_mant; end
        end
    end
endmodule
`default_nettype wire
