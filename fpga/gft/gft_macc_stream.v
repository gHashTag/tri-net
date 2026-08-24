`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_macc_stream -- byte-stream protocol core for the streaming GF-T16 MAC.
// Sits between the (proven) UART RX and TX in gft_macc_ax7203. Assembles per-term
// frames and folds each term into gft_macc; emits the accumulator on the LAST term.
//
//   per-term frame: [0xAA][0x55][a_lo a_hi][b_lo b_hi][ctrl]
//     ctrl bit0 = first (start a fresh accumulation)
//     ctrl bit1 = last  (this term completes the dot product -> emit acc)
//   response on last: out_valid pulse with out_y = accumulated dot product.
//
// Tested at the byte level (rx_new/rx_byte in, out_valid/out_y out) so the KAT needs
// no UART baud timing. Packed GF-T16 magnitudes throughout.
// ============================================================================
module gft_macc_stream (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_new,
    input  wire [7:0]  rx_byte,
    output wire        out_valid,
    output wire [15:0] out_y
);
    reg [2:0]  frm;
    reg [15:0] op_a, op_b;
    reg [7:0]  ctrl_r;
    reg        fold;      // 1-cycle pulse: fold (op_a,op_b) into the MAC

    always @(posedge clk or posedge rst) begin
        if (rst) begin frm<=0; op_a<=0; op_b<=0; ctrl_r<=0; fold<=0; end
        else begin
            fold <= 1'b0;
            if (rx_new) begin
                case (frm)
                    3'd0: frm <= (rx_byte==8'hAA) ? 3'd1 : 3'd0;
                    3'd1: frm <= (rx_byte==8'h55) ? 3'd2 : 3'd0;
                    3'd2: begin op_a[7:0]  <= rx_byte; frm <= 3'd3; end
                    3'd3: begin op_a[15:8] <= rx_byte; frm <= 3'd4; end
                    3'd4: begin op_b[7:0]  <= rx_byte; frm <= 3'd5; end
                    3'd5: begin op_b[15:8] <= rx_byte; frm <= 3'd6; end
                    3'd6: begin ctrl_r <= rx_byte; fold <= 1'b1; frm <= 3'd0; end
                    default: frm <= 3'd0;
                endcase
            end
        end
    end

    // gft_macc folds the term the cycle `fold` is high; acc settles one cycle later.
    wire [15:0] acc;
    gft_macc u_macc (
        .clk(clk), .rst(rst),
        .in_valid(fold), .first(ctrl_r[0]), .a(op_a), .b(op_b),
        .acc(acc));

    // Emit one cycle after a LAST-term fold, when acc holds the completed sum.
    reg emit;
    always @(posedge clk or posedge rst) begin
        if (rst) emit <= 1'b0;
        else     emit <= fold & ctrl_r[1];
    end

    assign out_valid = emit;
    assign out_y     = acc;
endmodule
`default_nettype wire
