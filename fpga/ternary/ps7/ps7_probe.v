`default_nettype none
// First-load probe for the Zynq-7020 PL. ZERO external pins by construction.
//
// Everything crosses to the PS over EMIO GPIO, which is internal routing, so
// this design cannot drive a board pin, cannot conflict with the AD9361 front
// end, and needs no pin constraints. That removes the three reasons the earlier
// ps7_tern design was never flashed: auto-placed pins, no PS-side program, and
// the risk of a non-verifiable no-op.
//
// The PS reads three things back and each answers one question:
//   ANCHOR    is OUR bitstream in the fabric, or someone else's?
//   HEARTBEAT does FCLK actually reach the fabric, or is the PL clockless?
//   MAC       does the ternary primitive compute, bit-exactly?
//
// EMIO input map (PL -> PS), 64 bits:
//   [15:0]  0x47C0   static anchor. Reading it proves this bitstream is live.
//   [24:16] y        9-bit signed result of the sign-select MAC.
//   [31:25] hb[6:0]  heartbeat, high bits of a free-running counter on FCLK.
//   [63:32] 0
//
// EMIO output map (PS -> PL):
//   [7:0]   x        signed sample
//   [9:8]   w        ternary weight: 01 -> +x, 10 -> -x, else 0
//
module ps7_probe;
    wire [3:0]  FCLKCLK;
    wire [3:0]  FCLKRESETN;
    wire [63:0] gpio_o;   // PS -> PL
    wire [63:0] gpio_i;   // PL -> PS
    wire [63:0] gpio_t;   // tri-state, unused

    wire clk   = FCLKCLK[0];
    wire rst_n = FCLKRESETN[0];

    wire signed [7:0] x = gpio_o[7:0];
    wire        [1:0] w = gpio_o[9:8];

    // Ternary sign-select MAC: the tri-net primitive, one LUT level, zero DSP.
    reg signed [8:0] y;
    always @(posedge clk) begin
        if (!rst_n) y <= 9'sd0;
        else case (w)
            2'b01:   y <= x;
            2'b10:   y <= -x;
            default: y <= 9'sd0;
        endcase
    end

    // Free-running counter on the PS-supplied clock. If FCLK is dead the high
    // bits never change and two reads a second apart return the same value.
    reg [30:0] cnt;
    always @(posedge clk) cnt <= (!rst_n) ? 31'd0 : cnt + 1'b1;

    // 0x47C0 is the project's cross-die anchor (phi^2 + phi^-2 = 3 -> GF16).
    // Here it serves a narrower purpose: it distinguishes "our bitstream is
    // loaded" from "the vendor bitstream is loaded" and from "the PL is blank",
    // which otherwise look identical from Linux.
    assign gpio_i = {32'd0, cnt[30:24], y, 16'h47C0};

    PS7 ps7_i (
        .FCLKCLK    (FCLKCLK),
        .FCLKRESETN (FCLKRESETN),
        .EMIOGPIOO  (gpio_o),
        .EMIOGPIOI  (gpio_i),
        .EMIOGPIOTN (gpio_t)
    );
endmodule
`default_nettype wire
