`default_nettype wire

// =============================================================================
// gft_mul8_ax7203 -- GF-T8 (compact edge rung) multiply engine for the ALINX AX7203.
// =============================================================================
// A surgical adaptation of the SILICON-PROVEN gf16_mul_ax7203 bring-up: the UART
// RX FSM (mid-bit sampling), frame assembler, and TX pattern are reused VERBATIM
// (all verified on real xc7a200t). The ONLY change is the arithmetic core --
// gf_mul_param -> gft_mul8_seq (the valid/ready wrapper around specs/tri_gft_arith
// gft_mul). One variable changed; everything around it is proven.
//
// Runs on CFGMCLK (~70 MHz, STARTUPE2 -> internal config clock). BAUD_DIV 434 (~161290 baud).
//
// Protocol (identical to the gf16 bring-up host script):
//   Host -> FPGA: [0xAA][0x55][a_lo][a_hi][b_lo][b_hi][cmd]
//   FPGA -> Host: [0xA5][res_lo][res_hi][0x00]
// Operands/result are GF-T16 magnitudes: [ offset:15..9 | mant:8..0 ], LE on the wire.
// =============================================================================

`timescale 1ns / 1ps

module gft_mul8_ax7203 (
    input  wire rst_n,
    input  wire uart_rx,
    output reg  uart_tx,
    output wire [3:0] led
);

    wire mclk, eos;
    STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) u_startup (
        .CFGCLK(), .CFGMCLK(mclk), .EOS(eos),
        .CLK(1'b0),.GSR(1'b0),.GTS(1'b0),.KEYCLEARB(1'b0),.PACK(1'b0),
        .USRCCLKO(1'b0),.USRCCLKTS(1'b0),.USRDONEO(1'b0),.USRDONETS(1'b0));
    wire rst = ~rst_n | ~eos;
    localparam [8:0] BAUD_DIV = 9'd434;

    // Heartbeat
    reg [26:0] cnt_c;
    always @(posedge mclk or posedge rst)
        if (rst) cnt_c <= 0; else cnt_c <= cnt_c + 1;
    assign led[0] = cnt_c[25];
    assign led[3] = ~rst;

    // ===== UART RX (from the proven bring-up -- mid-bit sampling) =====
    reg [2:0] rsync;
    always @(posedge mclk or posedge rst)
        if (rst) rsync <= 3'b111; else rsync <= {rsync[1:0], uart_rx};
    wire rxd = rsync[2];

    reg [1:0]  rxs;
    reg [9:0]  rxcnt;
    reg [2:0]  rbi;
    reg [7:0]  rxsr;
    reg [7:0]  rx_byte;
    reg        rx_new;

    always @(posedge mclk or posedge rst) begin
        if (rst) begin rxs<=0; rxcnt<=0; rbi<=0; rxsr<=0; rx_byte<=0; rx_new<=0; end
        else begin
            rx_new <= 0;
            case (rxs)
                2'd0: if (~rxd) begin rxcnt <= (BAUD_DIV + (BAUD_DIV>>1)) - 1; rxs<=1; rbi<=0; end
                2'd1: begin
                    if (rxcnt==0) begin
                        rxsr <= {rxd, rxsr[7:1]};
                        if (rbi==7) begin rxs<=2; rxcnt<=BAUD_DIV-1; end
                        else begin rbi<=rbi+1; rxcnt<=BAUD_DIV-1; end
                    end else rxcnt<=rxcnt-1;
                end
                2'd2: begin
                    if (rxcnt==0) begin rx_byte<=rxsr; rx_new<=1; rxs<=0; end
                    else rxcnt<=rxcnt-1;
                end
                default: rxs<=0;
            endcase
        end
    end

    // ===== Frame assembly: [AA 55 a_lo a_hi b_lo b_hi cmd] -> frame_valid =====
    reg [2:0] frm;
    reg [15:0] op_a, op_b;
    reg frame_valid;

    always @(posedge mclk or posedge rst) begin
        if (rst) begin frm<=0; op_a<=0; op_b<=0; frame_valid<=0; end
        else begin
            frame_valid <= 0;
            if (rx_new) begin
                case (frm)
                    3'd0: frm <= (rx_byte==8'hAA) ? 3'd1 : 3'd0;
                    3'd1: frm <= (rx_byte==8'h55) ? 3'd2 : 3'd0;
                    3'd2: begin op_a[7:0]  <= rx_byte; frm <= 3'd3; end
                    3'd3: begin op_a[15:8] <= rx_byte; frm <= 3'd4; end
                    3'd4: begin op_b[7:0]  <= rx_byte; frm <= 3'd5; end
                    3'd5: begin op_b[15:8] <= rx_byte; frm <= 3'd6; end
                    3'd6: begin frame_valid <= 1; frm <= 3'd0; end
                endcase
            end
        end
    end

    // ===== GF-T16 multiply core: gft_mul8_seq (valid/ready wrapper over gft_mul) =====
    wire mul_in_ready, mul_out_valid;
    wire [15:0] mul_out_y16;
    gft_mul8_seq u_mul (
        .clk(mclk), .rst(rst),
        .in_valid(frame_valid), .in_a(op_a[15:0]), .in_b(op_b[15:0]),
        .in_ready(mul_in_ready), .out_valid(mul_out_valid),
        .out_y(mul_out_y16), .out_ready(1'b1));
    wire [15:0] result_y = mul_out_y16;

    assign led[1] = frame_valid;
    assign led[2] = mul_out_valid;

    // ===== UART TX: send [A5 res_lo res_hi 00] on mul_out_valid (proven TX pattern) =====
    reg        responding;
    reg [1:0]  tx_idx;
    reg [7:0]  tx_buf0, tx_buf1, tx_buf2, tx_buf3;

    reg [8:0]  tcnt;
    reg [3:0]  tbi;
    reg [9:0]  tsr;

    always @(posedge mclk or posedge rst) begin
        if (rst) begin
            responding<=0; tx_idx<=0;
            tcnt<=BAUD_DIV-1; tbi<=0; tsr<=10'h3FF; uart_tx<=1;
            tx_buf0<=8'hFF; tx_buf1<=8'hFF; tx_buf2<=8'hFF; tx_buf3<=8'hFF;
        end else begin
            uart_tx <= tsr[0];

            // Capture result on core done
            if (mul_out_valid) begin
                tx_buf0 <= 8'hA5;
                tx_buf1 <= result_y[7:0];
                tx_buf2 <= result_y[15:8];
                tx_buf3 <= 8'h00;
                responding <= 1;
                tx_idx <= 0;
            end

            // TX shift
            if (tcnt==0) begin
                tcnt <= BAUD_DIV-1;
                if (tbi==9) begin
                    tbi <= 0;
                    if (responding) begin
                        case (tx_idx)
                            2'd0: tsr <= {1'b1, tx_buf0, 1'b0};
                            2'd1: tsr <= {1'b1, tx_buf1, 1'b0};
                            2'd2: tsr <= {1'b1, tx_buf2, 1'b0};
                            2'd3: tsr <= {1'b1, tx_buf3, 1'b0};
                        endcase
                        if (tx_idx==3) responding <= 0;
                        else tx_idx <= tx_idx + 1;
                    end else begin
                        tsr <= 10'h3FF;  // idle (line high)
                    end
                end else begin
                    tbi <= tbi + 1;
                    tsr <= {1'b1, tsr[9:1]};
                end
            end else begin
                tcnt <= tcnt - 1;
            end
        end
    end

endmodule

`default_nettype wire
