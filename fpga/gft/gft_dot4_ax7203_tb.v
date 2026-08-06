`timescale 1ns / 1ps
`default_nettype none
// Full-top UART simulation of gft_dot4_ax7203: drive the frame at the RX pin at BAUD_DIV
// timing, decode the TX response, and check it equals the expected dot product. Root-cause
// diagnostic for the on-silicon silence -- if this passes, the RTL top is correct and the
// bitstream/PnR is at fault; if it fails, the bug is here.

module STARTUPE2 #(parameter PROG_USR = "FALSE", parameter SIM_CCLK_FREQ = 0.0) (
    output wire CFGMCLK, output wire EOS,
    output wire CFGCLK,
    input wire CLK, input wire GSR, input wire GTS, input wire KEYCLEARB,
    input wire PACK, input wire USRCCLKO, input wire USRCCLKTS, input wire USRDONEO, input wire USRDONETS
);
    reg clk = 0;
    always #7 clk = ~clk;      // ~71 MHz CFGMCLK
    assign CFGMCLK = clk;
    assign EOS = 1'b1;
    assign CFGCLK = 1'b0;
endmodule

module gft_dot4_ax7203_tb;
    reg  rst_n = 0;
    reg  uart_rx = 1;
    wire uart_tx;
    wire [3:0] led;

    gft_dot4_ax7203 dut (.rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led));

    localparam integer BIT_NS = 434 * 14;  // BAUD_DIV=434 * ~14ns CFGMCLK period

    task send_byte; input [7:0] b; integer i;
        begin
            uart_rx = 1'b0; #(BIT_NS);                 // start
            for (i = 0; i < 8; i = i + 1) begin uart_rx = b[i]; #(BIT_NS); end
            uart_rx = 1'b1; #(BIT_NS);                 // stop
        end
    endtask

    task send16; input [15:0] x; begin send_byte(x[7:0]); send_byte(x[15:8]); end endtask

    // capture 4 TX bytes
    reg [7:0] rx_bytes [0:3];
    integer   nrx = 0;
    task recv_byte; output [7:0] b; integer i;
        begin
            @(negedge uart_tx);          // start bit
            #(BIT_NS + BIT_NS/2);        // to middle of bit0
            for (i = 0; i < 8; i = i + 1) begin b[i] = uart_tx; #(BIT_NS); end
        end
    endtask

    reg [7:0] tb;
    integer k;
    initial begin
        #200 rst_n = 1;
        #(BIT_NS * 4);
        // frame: AA 55 [4x (41,0)=0x5200 pairs] cmd -> expect 0x5800
        send_byte(8'hAA); send_byte(8'h55);
        send16(16'h5200); send16(16'h5200); // a0,b0
        send16(16'h5200); send16(16'h5200); // a1,b1
        send16(16'h5200); send16(16'h5200); // a2,b2
        send16(16'h5200); send16(16'h5200); // a3,b3
        send_byte(8'h01);                   // cmd
    end

    initial begin
        for (k = 0; k < 4; k = k + 1) begin recv_byte(tb); rx_bytes[k] = tb; end
        $display("TX response: %02h %02h %02h %02h", rx_bytes[0], rx_bytes[1], rx_bytes[2], rx_bytes[3]);
        if (rx_bytes[0] == 8'hA5 && {rx_bytes[2], rx_bytes[1]} == 16'h5800)
            $display("gft_dot4_ax7203 TOP SIM PASS -> 0x5800");
        else
            $display("gft_dot4_ax7203 TOP SIM FAIL (want A5 00 58 00)");
        $finish;
    end

    initial begin #50_000_000 $display("TIMEOUT: no TX response"); $finish; end
endmodule
`default_nettype wire
