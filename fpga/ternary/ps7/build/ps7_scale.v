`default_nettype none
// Two 63-tap despreaders side by side, to put ~19 000 LUT of our own logic
// through place-and-route -- the size the full image (axi_ad9361 7 447 +
// axi_dmac 725 + one correlator 9 534 = 17 706) would reach. The question is
// not what this design computes; it is whether nextpnr can place and route
// that much on this chipdb, in what runtime, and at what clock.
module ps7_scale;
    localparam W = 16, ACC = 24, N = 63, AW = 6;
    wire [3:0] FCLKCLK, FCLKRESETN;
    wire [63:0] gpio_o, gpio_i, gpio_t;
    wire clk = FCLKCLK[0];
    wire rst = ~FCLKRESETN[0] | gpio_o[17];

    wire signed [ACC-1:0] m0, m1;
    wire v0, v1;
    tern_corr_pn_tree #(.N(N),.W(W),.ACC(ACC),.AW(AW)) u0 (
        .clk(clk), .rst(rst), .s_valid(gpio_o[16]), .s_data(gpio_o[15:0]),
        .c_wr(gpio_o[18]), .c_addr(gpio_o[24:19]), .c_data(gpio_o[26:25]),
        .m_valid(v0), .m_data(m0));
    tern_corr_pn_tree #(.N(N),.W(W),.ACC(ACC),.AW(AW)) u1 (
        .clk(clk), .rst(rst), .s_valid(gpio_o[27]), .s_data(gpio_o[43:28]),
        .c_wr(gpio_o[44]), .c_addr(gpio_o[50:45]), .c_data(gpio_o[52:51]),
        .m_valid(v1), .m_data(m1));

    reg signed [ACC-1:0] h0, h1;
    always @(posedge clk) begin
        if (v0) h0 <= m0;
        if (v1) h1 <= m1;
    end
    assign gpio_i = {14'd0, h1, h0, 16'h47C0};
    PS7 ps7_i (.FCLKCLK(FCLKCLK), .FCLKRESETN(FCLKRESETN),
               .EMIOGPIOO(gpio_o), .EMIOGPIOI(gpio_i), .EMIOGPIOTN(gpio_t));
endmodule
`default_nettype wire
