`default_nettype wire

// =============================================================================
// gft_mul64_ax7203 -- GF-T64 multiply engine for the ALINX AX7203.
// =============================================================================
// Silicon-proven UART RX skeleton (as gft_mul32_ax7203) + gft_mul64_stream (79-bit
// operands: 15b offset + 64b mantissa) + a WIDENED 12-byte TX for the 79-bit result.
// CFGMCLK (~70 MHz), BAUD_DIV 434 (~161290 baud).
//
// Frame : [0xAA][0x55][a_off:2 LE][a_mant:8 LE][b_off:2 LE][b_mant:8 LE][cmd]
// Reply : [0xA5][out_off:2 LE][out_mant:8 LE][0x00]
// GF-T64: value = (1 + mant/2^64) * 2^(offset - 9841).
// =============================================================================

`timescale 1ns / 1ps

module gft_mul64_ax7203 (
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

    // ===== UART RX (proven mid-bit sampling) =====
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

    // ===== GF-T64 datapath =====
    wire        dv;
    wire [15:0] r_off;
    wire [63:0] r_mant;
    gft_mul64_stream u_stream (
        .clk(mclk), .rst(rst), .rx_new(rx_new), .rx_byte(rx_byte),
        .out_valid(dv), .out_off(r_off), .out_mant(r_mant));

    assign led[1] = rx_new;
    assign led[2] = dv;

    // ===== UART TX: 12 bytes [A5 off_lo off_hi m0..m7 00] on dv =====
    reg        responding;
    reg [3:0]  tx_idx;
    reg [7:0]  tb [0:11];
    reg [8:0]  tcnt; reg [3:0] tbi; reg [9:0] tsr;
    reg [7:0]  tx_cur;

    always @(*) tx_cur = tb[tx_idx];

    integer i;
    always @(posedge mclk or posedge rst) begin
        if (rst) begin
            responding<=0; tx_idx<=0; tcnt<=BAUD_DIV-1; tbi<=0; tsr<=10'h3FF; uart_tx<=1;
            for (i=0;i<12;i=i+1) tb[i] <= 8'hFF;
        end else begin
            uart_tx <= tsr[0];
            if (dv) begin
                tb[0]<=8'hA5; tb[1]<=r_off[7:0]; tb[2]<=r_off[15:8];
                tb[3]<=r_mant[7:0];   tb[4]<=r_mant[15:8];  tb[5]<=r_mant[23:16]; tb[6]<=r_mant[31:24];
                tb[7]<=r_mant[39:32]; tb[8]<=r_mant[47:40]; tb[9]<=r_mant[55:48]; tb[10]<=r_mant[63:56];
                tb[11]<=8'h00; responding<=1; tx_idx<=0;
            end
            if (tcnt==0) begin
                tcnt <= BAUD_DIV-1;
                if (tbi==9) begin
                    tbi <= 0;
                    if (responding) begin
                        tsr <= {1'b1, tx_cur, 1'b0};
                        if (tx_idx==11) responding <= 0;
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
