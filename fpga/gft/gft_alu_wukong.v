`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_alu_wukong -- the gft_alu_selfcheck proof top for the board the silicon
// evidence actually belongs to: the QMTech Wukong V1 (xc7a200tfbg676-1), the
// three boards t27's fpga/HARDWARE_SSOT.md measured (IDCODE 0x13636093,
// CFGMCLK 70.77/68.49/67.20 MHz, 2026-08-17). The ax7203 top stays a flow
// artefact; this one is pin-complete from proven data only:
//
//   clock  STARTUPE2 CFGMCLK / 8 = 8.85 MHz on the fastest die (T495),
//          against the 25.46 MHz Fmax this ALU measured in P&R (seed 1,
//          2026-08-20) -- a 2.9x margin, stated, W838/W839 style.
//   reset  internal 16-cycle counter, no board key needed.
//   LEDs   D5 = pass, D6 = fail -- LVCMOS33, the pins t27's find_led /
//          static_d5 / blink_j26 lineage proved by flashing (DONE observed).
//
// Everything the selfcheck walks is the over-wire GF-T16 known-answer set;
// see gft_alu_selfcheck.v. `pass` lights D5 iff every vector matched.
// ============================================================================
module gft_alu_wukong (
    output wire d5,   // pass LED, package pin D5
    output wire d6    // fail LED, package pin D6
);

    wire cfgmclk;
    STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(10.0)) startup (
        .CFGCLK(), .CFGMCLK(cfgmclk), .EOS(), .PREQ(),
        .CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b0),
        .PACK(1'b0), .USRCCLKO(1'b0), .USRCCLKTS(1'b0),
        .USRDONEO(1'b1), .USRDONETS(1'b1));

    reg [2:0] dv = 3'd0;
    always @(posedge cfgmclk) dv <= dv + 3'd1;
    wire slowclk;
    BUFG bufg_slow (.I(dv[2]), .O(slowclk));

    reg [3:0] rstc = 4'd0;
    wire rst_n = (rstc == 4'hF);
    always @(posedge slowclk) if (rstc != 4'hF) rstc <= rstc + 4'd1;

    wire pass, fail;
    gft_alu_selfcheck u_selfcheck (
        .clk  (slowclk),
        .rst_n(rst_n),
        .pass (pass),
        .fail (fail)
    );

    assign d5 = pass;
    assign d6 = fail;

endmodule
`default_nettype wire
