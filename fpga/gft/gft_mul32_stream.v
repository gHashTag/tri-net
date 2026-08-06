`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_mul32_stream -- byte-stream protocol core for the GF-T32 wide multiplier.
// GF-T32 operands are 35-bit (10-bit offset + 25-bit mantissa), so each is carried
// as offset (2 bytes LE) + mantissa (4 bytes LE). Assembles one frame, folds it
// through gft_mul32, emits the 35-bit result (offset 2B + mantissa 4B).
//
//   frame: [0xAA][0x55][a_off:2][a_mant:4][b_off:2][b_mant:4][cmd]
//   emit : out_valid pulse with out_off (16b) + out_mant (32b)
// Tested at the byte level (no UART baud) via gft_mul32_stream_tb.
// ============================================================================
module gft_mul32_stream (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_new,
    input  wire [7:0]  rx_byte,
    output reg         out_valid,
    output reg  [15:0] out_off,
    output reg  [31:0] out_mant
);
    reg [3:0]  frm;
    reg [15:0] a_off, b_off;
    reg [31:0] a_mant, b_mant;
    reg        fold;

    always @(posedge clk or posedge rst) begin
        if (rst) begin frm<=0; a_off<=0; b_off<=0; a_mant<=0; b_mant<=0; fold<=0; end
        else begin
            fold <= 1'b0;
            if (rx_new) begin
                case (frm)
                    4'd0:  frm <= (rx_byte==8'hAA) ? 4'd1 : 4'd0;
                    4'd1:  frm <= (rx_byte==8'h55) ? 4'd2 : 4'd0;
                    4'd2:  begin a_off[7:0]    <= rx_byte; frm <= 4'd3;  end
                    4'd3:  begin a_off[15:8]   <= rx_byte; frm <= 4'd4;  end
                    4'd4:  begin a_mant[7:0]   <= rx_byte; frm <= 4'd5;  end
                    4'd5:  begin a_mant[15:8]  <= rx_byte; frm <= 4'd6;  end
                    4'd6:  begin a_mant[23:16] <= rx_byte; frm <= 4'd7;  end
                    4'd7:  begin a_mant[31:24] <= rx_byte; frm <= 4'd8;  end
                    4'd8:  begin b_off[7:0]    <= rx_byte; frm <= 4'd9;  end
                    4'd9:  begin b_off[15:8]   <= rx_byte; frm <= 4'd10; end
                    4'd10: begin b_mant[7:0]   <= rx_byte; frm <= 4'd11; end
                    4'd11: begin b_mant[15:8]  <= rx_byte; frm <= 4'd12; end
                    4'd12: begin b_mant[23:16] <= rx_byte; frm <= 4'd13; end
                    4'd13: begin b_mant[31:24] <= rx_byte; frm <= 4'd14; end
                    4'd14: begin fold <= 1'b1; frm <= 4'd0; end
                    default: frm <= 4'd0;
                endcase
            end
        end
    end

    // Combinational GF-T32 multiply on the latched operands.
    wire [31:0] o_off, o_mant;
    gft_mul32 #(.BIAS(364), .OFFSET_MAX(728), .MANT_ONE(64'd33554432)) u_mul (
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
