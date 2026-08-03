`default_nettype none
// THE POINT OF THE WHOLE EXERCISE: our multiplierless 63-tap despreader sitting
// inside ADI's AD9361 receive datapath, in one bitstream.
//
// The correlator is fed from axi_ad9361's adc_data_i0 / adc_valid_i0 and
// clocked on l_clk -- the recovered bus clock -- so it is genuinely in the
// receive path rather than beside it.
//
// ZERO package pins. The AD9361 bus is driven from an LFSR inside the fabric
// instead of from real pins, and everything observable crosses over EMIO. That
// is deliberate: the vendor design drives all 30 of the pins an earlier harness
// picked (see ../PINOUT.md), so any design with real outputs on those banks is
// unsafe to load on this board until the per-pin direction is known.
//
// IODELAY_CTRL(0) with FPGA_TECHNOLOGY(0) keeps the delay controller out: with
// no IDELAYs instantiated an IDELAYCTRL is orphaned, and openXC7 rejects that.
// It also removes the IDELAYE2 whose IDATAIN cannot be driven by a flip-flop.
//
// EMIO in: [15:0] 0x47C0 anchor | [39:16] corr | [47:40] count | [48] adc_valid seen
module ps7_ad9361_corr;
    localparam W=16, ACC=24, N=63, AW=6;
    wire [3:0] FCLKCLK, FCLKRESETN;
    wire [63:0] gpio_o, gpio_i, gpio_t;
    wire clk = FCLKCLK[0];
    wire rst = ~FCLKRESETN[0] | gpio_o[0];
    reg [63:0] lfsr = 64'hA5A5_1234_DEAD_BEEF;
    always @(posedge clk) if (rst) lfsr <= 64'hA5A5_1234_DEAD_BEEF;
        else lfsr <= {lfsr[62:0], lfsr[63]^lfsr[62]^lfsr[60]^lfsr[59]};
    wire o_tx_clk_out_p;
    wire o_tx_clk_out_n;
    wire o_tx_frame_out_p;
    wire o_tx_frame_out_n;
    wire [5:0] o_tx_data_out_p;
    wire [5:0] o_tx_data_out_n;
    wire o_tx_clk_out;
    wire o_tx_frame_out;
    wire [11:0] o_tx_data_out;
    wire o_enable;
    wire o_txnrx;
    wire o_dac_sync_out;
    wire o_tdd_sync_cntr;
    wire o_gps_pps_irq;
    wire o_l_clk;
    wire o_rst;
    wire o_adc_enable_i0;
    wire o_adc_valid_i0;
    wire [15:0] o_adc_data_i0;
    wire o_adc_enable_q0;
    wire o_adc_valid_q0;
    wire [15:0] o_adc_data_q0;
    wire o_adc_enable_i1;
    wire o_adc_valid_i1;
    wire [15:0] o_adc_data_i1;
    wire o_adc_enable_q1;
    wire o_adc_valid_q1;
    wire [15:0] o_adc_data_q1;
    wire o_adc_r1_mode;
    wire o_dac_enable_i0;
    wire o_dac_valid_i0;
    wire o_dac_enable_q0;
    wire o_dac_valid_q0;
    wire o_dac_enable_i1;
    wire o_dac_valid_i1;
    wire o_dac_enable_q1;
    wire o_dac_valid_q1;
    wire o_dac_r1_mode;
    wire o_s_axi_awready;
    wire o_s_axi_wready;
    wire o_s_axi_bvalid;
    wire [1:0] o_s_axi_bresp;
    wire o_s_axi_arready;
    wire o_s_axi_rvalid;
    wire [31:0] o_s_axi_rdata;
    wire [1:0] o_s_axi_rresp;
    wire [31:0] o_up_dac_gpio_out;
    wire [31:0] o_up_adc_gpio_out;

    axi_ad9361 #(.FPGA_TECHNOLOGY(0), .IODELAY_CTRL(0), .CMOS_OR_LVDS_N(1)) u_rx (
        .rx_clk_in_p (lfsr[0]),
        .rx_clk_in_n (lfsr[1]),
        .rx_frame_in_p (lfsr[2]),
        .rx_frame_in_n (lfsr[3]),
        .rx_data_in_p (lfsr[5:0]),
        .rx_data_in_n (lfsr[5:0]),
        .rx_clk_in (lfsr[6]),
        .rx_frame_in (lfsr[7]),
        .rx_data_in (lfsr[11:0]),
        .dac_sync_in (lfsr[9]),
        .tdd_sync (lfsr[10]),
        .gps_pps (lfsr[11]),
        .delay_clk (clk),
        .clk (clk),
        .adc_dovf (lfsr[14]),
        .dac_data_i0 (lfsr[15:0]),
        .dac_data_q0 (lfsr[15:0]),
        .dac_data_i1 (lfsr[15:0]),
        .dac_data_q1 (lfsr[15:0]),
        .dac_dunf (lfsr[19]),
        .s_axi_aclk (clk),
        .s_axi_aresetn (lfsr[21]),
        .s_axi_awvalid (lfsr[22]),
        .s_axi_awaddr (lfsr[15:0]),
        .s_axi_awprot (lfsr[2:0]),
        .s_axi_wvalid (lfsr[25]),
        .s_axi_wdata (lfsr[31:0]),
        .s_axi_wstrb (lfsr[3:0]),
        .s_axi_bready (lfsr[28]),
        .s_axi_arvalid (lfsr[29]),
        .s_axi_araddr (lfsr[15:0]),
        .s_axi_arprot (lfsr[2:0]),
        .s_axi_rready (lfsr[32]),
        .up_enable (lfsr[33]),
        .up_txnrx (lfsr[34]),
        .up_dac_gpio_in (lfsr[31:0]),
        .up_adc_gpio_in (lfsr[31:0]),
        .tx_clk_out_p (o_tx_clk_out_p),
        .tx_clk_out_n (o_tx_clk_out_n),
        .tx_frame_out_p (o_tx_frame_out_p),
        .tx_frame_out_n (o_tx_frame_out_n),
        .tx_data_out_p (o_tx_data_out_p),
        .tx_data_out_n (o_tx_data_out_n),
        .tx_clk_out (o_tx_clk_out),
        .tx_frame_out (o_tx_frame_out),
        .tx_data_out (o_tx_data_out),
        .enable (o_enable),
        .txnrx (o_txnrx),
        .dac_sync_out (o_dac_sync_out),
        .tdd_sync_cntr (o_tdd_sync_cntr),
        .gps_pps_irq (o_gps_pps_irq),
        .l_clk (o_l_clk),
        .rst (o_rst),
        .adc_enable_i0 (o_adc_enable_i0),
        .adc_valid_i0 (o_adc_valid_i0),
        .adc_data_i0 (o_adc_data_i0),
        .adc_enable_q0 (o_adc_enable_q0),
        .adc_valid_q0 (o_adc_valid_q0),
        .adc_data_q0 (o_adc_data_q0),
        .adc_enable_i1 (o_adc_enable_i1),
        .adc_valid_i1 (o_adc_valid_i1),
        .adc_data_i1 (o_adc_data_i1),
        .adc_enable_q1 (o_adc_enable_q1),
        .adc_valid_q1 (o_adc_valid_q1),
        .adc_data_q1 (o_adc_data_q1),
        .adc_r1_mode (o_adc_r1_mode),
        .dac_enable_i0 (o_dac_enable_i0),
        .dac_valid_i0 (o_dac_valid_i0),
        .dac_enable_q0 (o_dac_enable_q0),
        .dac_valid_q0 (o_dac_valid_q0),
        .dac_enable_i1 (o_dac_enable_i1),
        .dac_valid_i1 (o_dac_valid_i1),
        .dac_enable_q1 (o_dac_enable_q1),
        .dac_valid_q1 (o_dac_valid_q1),
        .dac_r1_mode (o_dac_r1_mode),
        .s_axi_awready (o_s_axi_awready),
        .s_axi_wready (o_s_axi_wready),
        .s_axi_bvalid (o_s_axi_bvalid),
        .s_axi_bresp (o_s_axi_bresp),
        .s_axi_arready (o_s_axi_arready),
        .s_axi_rvalid (o_s_axi_rvalid),
        .s_axi_rdata (o_s_axi_rdata),
        .s_axi_rresp (o_s_axi_rresp),
        .up_dac_gpio_out (o_up_dac_gpio_out),
        .up_adc_gpio_out (o_up_adc_gpio_out)
    );

    // ---- our core, in the receive path ----
    wire lclk = o_l_clk;
    wire signed [ACC-1:0] m_data; wire m_valid;
    reg [AW-1:0] tap_addr = 0; reg tap_wr = 0; reg taps_done = 0;
    always @(posedge lclk) begin
        if (rst) begin tap_addr<=0; tap_wr<=0; taps_done<=0; end
        else if (!taps_done) begin
            tap_wr <= 1'b1;
            if (tap_wr) begin
                if (tap_addr == N-1) begin taps_done<=1'b1; tap_wr<=1'b0; end
                else tap_addr <= tap_addr + 1'b1;
            end
        end else tap_wr <= 1'b0;
    end
    // matched PN taps, +1/-1 alternating pattern from the m-sequence
    wire [1:0] tap_code = (tap_addr[0] ^ tap_addr[2] ^ tap_addr[4]) ? 2'b01 : 2'b10;

    tern_corr_pn_tree #(.N(N),.W(W),.ACC(ACC),.AW(AW)) u_corr (
        .clk(lclk), .rst(rst | ~taps_done),
        .s_valid(o_adc_valid_i0), .s_data(o_adc_data_i0),
        .c_wr(tap_wr), .c_addr(tap_addr), .c_data(tap_code),
        .m_valid(m_valid), .m_data(m_data));

    reg signed [ACC-1:0] corr_hold = 0; reg [7:0] cnt = 0; reg saw_valid = 0;
    always @(posedge lclk) begin
        if (rst) begin corr_hold<=0; cnt<=0; saw_valid<=0; end
        else begin
            if (m_valid) corr_hold <= m_data;
            if (o_adc_valid_i0) begin cnt <= cnt + 8'd1; saw_valid <= 1'b1; end
        end
    end
    assign gpio_i = {15'd0, saw_valid, cnt, corr_hold, 16'h47C0};

    PS7 ps7_i (.FCLKCLK(FCLKCLK), .FCLKRESETN(FCLKRESETN),
               .EMIOGPIOO(gpio_o), .EMIOGPIOI(gpio_i), .EMIOGPIOTN(gpio_t));
endmodule
`default_nettype wire
