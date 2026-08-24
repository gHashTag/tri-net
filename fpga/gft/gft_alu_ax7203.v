`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// gft_alu_ax7203 -- board top for the GF-T ALU self-check on the ALINX AX7203
// Ports match the proven blinky_ax7203 top (clk200_p/clk200_n/rst_n/led[3:0], per the
// ax7203-blinky nextpnr.log), so the board's EXISTING blinky XDC applies unchanged.
// (XC7A200T-FBG484-2). The board clock is a 200 MHz DIFFERENTIAL pair (DIFF_SSTL15,
// clk200_p on R4) buffered through an IBUFDS; the self-check drives two LEDs: led[0]=pass,
// led[1]=fail. Flashing this and seeing led[0] is the first GF-T recompute on silicon.
//
// Simulate the whole chain with -DSIM (behavioral clock buffer, no unisim needed):
//   iverilog -g2012 -DSIM -o sc.vvp fpga/gft/gft_mul.v fpga/gft/gft_add.v \
//     fpga/gft/gft_sub.v fpga/gft/gft_alu.v fpga/gft/gft_alu_selfcheck.v \
//     fpga/gft/gft_alu_ax7203.v <tb>
// Synthesis (no -DSIM) uses the real IBUFDS primitive.
// ============================================================================
module gft_alu_ax7203 (
    input  wire       clk200_p,   // 200 MHz DIFF_SSTL15 (+), package pin R4
    input  wire       clk200_n,   // 200 MHz DIFF_SSTL15 (-), paired pin (verify vs board)
    input  wire       rst_n,   // active-low reset (a board key)
    output wire [3:0] led      // led[0]=pass, led[1]=fail
);
    wire clk;
`ifdef SIM
    assign clk = clk200_p;        // behavioral buffer for iverilog
`else
    IBUFDS #(.DIFF_TERM("TRUE"), .IOSTANDARD("DIFF_SSTL15")) u_clk (.O(clk), .I(clk200_p), .IB(clk200_n));
`endif
    wire pass, fail;
    gft_alu_selfcheck u_sc (.clk(clk), .rst_n(rst_n), .pass(pass), .fail(fail));
    assign led = {2'b00, fail, pass};
endmodule
`default_nettype wire
