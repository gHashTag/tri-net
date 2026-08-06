`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_dot4_stream -- byte-stream protocol core for the 4-lane GF-T16 tile
// (gft_dot4_tile). Collects eight packed GF-T16 operands (a0,b0..a3,b3), packs them
// into the tile's lane layout, and emits the 4-term dot product in one shot.
//
//   frame: [0xAA][0x55][a0:2][b0:2][a1:2][b1:2][a2:2][b2:2][a3:2][b3:2][cmd]
//   emit : out_valid pulse with out_y = a0*b0 + a1*b1 + a2*b2 + a3*b3 (packed GF-T16)
// The tile result is 16 bits, so the proven 4-byte TX carries it unchanged.
// ============================================================================
module gft_dot4_stream (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_new,
    input  wire [7:0]  rx_byte,
    output reg         out_valid,
    output reg  [15:0] out_y
);
    reg [4:0]  frm;
    reg [15:0] a0, b0, a1, b1, a2, b2, a3, b3;
    reg        fold;

    always @(posedge clk or posedge rst) begin
        if (rst) begin frm<=0; fold<=0; a0<=0;b0<=0;a1<=0;b1<=0;a2<=0;b2<=0;a3<=0;b3<=0; end
        else begin
            fold <= 1'b0;
            if (rx_new) begin
                case (frm)
                    5'd0:  frm <= (rx_byte==8'hAA) ? 5'd1 : 5'd0;
                    5'd1:  frm <= (rx_byte==8'h55) ? 5'd2 : 5'd0;
                    5'd2:  begin a0[7:0]<=rx_byte; frm<=5'd3;  end
                    5'd3:  begin a0[15:8]<=rx_byte; frm<=5'd4;  end
                    5'd4:  begin b0[7:0]<=rx_byte; frm<=5'd5;  end
                    5'd5:  begin b0[15:8]<=rx_byte; frm<=5'd6;  end
                    5'd6:  begin a1[7:0]<=rx_byte; frm<=5'd7;  end
                    5'd7:  begin a1[15:8]<=rx_byte; frm<=5'd8;  end
                    5'd8:  begin b1[7:0]<=rx_byte; frm<=5'd9;  end
                    5'd9:  begin b1[15:8]<=rx_byte; frm<=5'd10; end
                    5'd10: begin a2[7:0]<=rx_byte; frm<=5'd11; end
                    5'd11: begin a2[15:8]<=rx_byte; frm<=5'd12; end
                    5'd12: begin b2[7:0]<=rx_byte; frm<=5'd13; end
                    5'd13: begin b2[15:8]<=rx_byte; frm<=5'd14; end
                    5'd14: begin a3[7:0]<=rx_byte; frm<=5'd15; end
                    5'd15: begin a3[15:8]<=rx_byte; frm<=5'd16; end
                    5'd16: begin b3[7:0]<=rx_byte; frm<=5'd17; end
                    5'd17: begin b3[15:8]<=rx_byte; frm<=5'd18; end
                    5'd18: begin fold <= 1'b1; frm <= 5'd0; end
                    default: frm <= 5'd0;
                endcase
            end
        end
    end

    // Pack into the tile lane layout: lane i uses a_off[7i +:7], a_mant[9i +:9].
    wire [27:0] a_off  = {a3[15:9], a2[15:9], a1[15:9], a0[15:9]};
    wire [35:0] a_mant = {a3[8:0],  a2[8:0],  a1[8:0],  a0[8:0]};
    wire [27:0] b_off  = {b3[15:9], b2[15:9], b1[15:9], b0[15:9]};
    wire [35:0] b_mant = {b3[8:0],  b2[8:0],  b1[8:0],  b0[8:0]};

    wire [6:0] o_off;
    wire [8:0] o_mant;
    gft_dot4_tile u_tile (.a_off(a_off), .a_mant(a_mant), .b_off(b_off), .b_mant(b_mant),
                          .out_off(o_off), .out_mant(o_mant));

    always @(posedge clk or posedge rst) begin
        if (rst) begin out_valid<=0; out_y<=0; end
        else begin
            out_valid <= fold;
            if (fold) out_y <= {o_off, o_mant};
        end
    end
endmodule
`default_nettype wire
