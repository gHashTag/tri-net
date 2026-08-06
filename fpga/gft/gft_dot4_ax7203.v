`default_nettype wire

// =============================================================================
// gft_dot4_ax7203 -- 4-lane GF-T16 tile (parallel MAC) for the ALINX AX7203.
// =============================================================================
// Silicon-proven UART RX/TX skeleton + gft_dot4_stream (collects 8 operands, runs the
// gft_dot4_tile = 4x gft16_mul + gft_add tree in one shot). Result is 16-bit, so the
// proven 4-byte TX carries it unchanged. CFGMCLK (~70 MHz), BAUD_DIV 434 (~161290 baud).
//
// Frame: [0xAA][0x55][a0:2][b0:2][a1:2][b1:2][a2:2][b2:2][a3:2][b3:2][cmd]
// Reply: [0xA5][y_lo][y_hi][0x00]  where y = a0*b0 + a1*b1 + a2*b2 + a3*b3 (GF-T16).
// =============================================================================

`timescale 1ns / 1ps

module gft_dot4_ax7203 (
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

    reg [26:0] cnt_c;
    always @(posedge mclk or posedge rst)
        if (rst) cnt_c <= 0; else cnt_c <= cnt_c + 1;
    assign led[0] = cnt_c[25];
    assign led[3] = ~rst;

    reg [2:0] rsync;
    always @(posedge mclk or posedge rst)
        if (rst) rsync <= 3'b111; else rsync <= {rsync[1:0], uart_rx};
    wire rxd = rsync[2];

    reg [1:0] rxs; reg [9:0] rxcnt; reg [2:0] rbi; reg [7:0] rxsr; reg [7:0] rx_byte; reg rx_new;
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

    wire dv;
    wire [15:0] r_y;
    gft_dot4_stream u_stream (.clk(mclk), .rst(rst), .rx_new(rx_new), .rx_byte(rx_byte),
                              .out_valid(dv), .out_y(r_y));
    wire [15:0] result_y = r_y;

    assign led[1] = rx_new;
    assign led[2] = dv;

    reg        responding;
    reg [1:0]  tx_idx;
    reg [7:0]  tx_buf0, tx_buf1, tx_buf2, tx_buf3;
    reg [8:0]  tcnt; reg [3:0] tbi; reg [9:0] tsr;

    always @(posedge mclk or posedge rst) begin
        if (rst) begin
            responding<=0; tx_idx<=0; tcnt<=BAUD_DIV-1; tbi<=0; tsr<=10'h3FF; uart_tx<=1;
            tx_buf0<=8'hFF; tx_buf1<=8'hFF; tx_buf2<=8'hFF; tx_buf3<=8'hFF;
        end else begin
            uart_tx <= tsr[0];
            if (dv) begin
                tx_buf0 <= 8'hA5; tx_buf1 <= result_y[7:0]; tx_buf2 <= result_y[15:8]; tx_buf3 <= 8'h00;
                responding <= 1; tx_idx <= 0;
            end
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
                    end else tsr <= 10'h3FF;
                end else begin
                    tbi <= tbi + 1;
                    tsr <= {1'b1, tsr[9:1]};
                end
            end else tcnt <= tcnt - 1;
        end
    end
endmodule

`default_nettype wire
