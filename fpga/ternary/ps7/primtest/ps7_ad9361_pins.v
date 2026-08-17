`default_nettype none
// P&R harness with REAL package pins for the AD9361 CMOS bus.
// The pin-less LFSR harness could not test the input-delay path: IDELAYE2's
// IDATAIN must come from a real IOB, and a flip-flop is not one. These 30
// ports are therefore genuine top-level pins, constrained in the XDC; every
// other input still comes from an LFSR so nothing can be folded away.
module ps7_ad9361_pins (
    input wire rx_clk_in,
    input wire rx_frame_in,
    input wire [11:0] rx_data_in,
    output wire tx_clk_out,
    output wire tx_frame_out,
    output wire [11:0] tx_data_out,
    output wire enable,
    output wire txnrx
);
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
    axi_ad9361 #(.FPGA_TECHNOLOGY(1), .CMOS_OR_LVDS_N(1)) u_dut (
        .rx_clk_in_p (lfsr[0]),
        .rx_clk_in_n (lfsr[1]),
        .rx_frame_in_p (lfsr[2]),
        .rx_frame_in_n (lfsr[3]),
        .rx_data_in_p (lfsr[5:0]),
        .rx_data_in_n (lfsr[5:0]),
        .rx_clk_in (rx_clk_in),
        .rx_frame_in (rx_frame_in),
        .rx_data_in (rx_data_in),
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
        .tx_clk_out (tx_clk_out),
        .tx_frame_out (tx_frame_out),
        .tx_data_out (tx_data_out),
        .enable (enable),
        .txnrx (txnrx),
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
    wire [42:0] red = {(^o_tx_clk_out_p), (^o_tx_clk_out_n), (^o_tx_frame_out_p), (^o_tx_frame_out_n), (^o_tx_data_out_p), (^o_tx_data_out_n), (^o_dac_sync_out), (^o_tdd_sync_cntr), (^o_gps_pps_irq), (^o_l_clk), (^o_rst), (^o_adc_enable_i0), (^o_adc_valid_i0), (^o_adc_data_i0), (^o_adc_enable_q0), (^o_adc_valid_q0), (^o_adc_data_q0), (^o_adc_enable_i1), (^o_adc_valid_i1), (^o_adc_data_i1), (^o_adc_enable_q1), (^o_adc_valid_q1), (^o_adc_data_q1), (^o_adc_r1_mode), (^o_dac_enable_i0), (^o_dac_valid_i0), (^o_dac_enable_q0), (^o_dac_valid_q0), (^o_dac_enable_i1), (^o_dac_valid_i1), (^o_dac_enable_q1), (^o_dac_valid_q1), (^o_dac_r1_mode), (^o_s_axi_awready), (^o_s_axi_wready), (^o_s_axi_bvalid), (^o_s_axi_bresp), (^o_s_axi_arready), (^o_s_axi_rvalid), (^o_s_axi_rdata), (^o_s_axi_rresp), (^o_up_dac_gpio_out), (^o_up_adc_gpio_out)};
    reg [31:0] sum = 32'd0;
    always @(posedge clk) if (rst) sum <= 0; else sum <= {sum[30:0], ^red} ^ {31'd0, ^sum};
    assign gpio_i = {16'd0, sum, 16'h47C0};
    PS7 ps7_i (.FCLKCLK(FCLKCLK), .FCLKRESETN(FCLKRESETN),
               .EMIOGPIOO(gpio_o), .EMIOGPIOI(gpio_i), .EMIOGPIOTN(gpio_t));
endmodule
`default_nettype wire
