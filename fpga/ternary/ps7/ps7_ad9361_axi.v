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
// FPGA_TECHNOLOGY WAS 0 AND THAT WAS WRONG. It kept the IDELAYCTRL out, but it
// also kept out the IDDR that captures receive data, because all three of
// ad_data_in's generate chains -- ibuf, idelay, iddr -- test the technology and
// none has a default branch. The receive datapath had no driver at all, so the
// data was structurally guaranteed to be zero whatever the control registers
// said. Nothing warned; the wires were simply never driven.
//
// The delay and the buffer are now switched off by parameter instead
// (IODELAY_ENABLE(0), NO_IBUF(1) -- see ../ADI_PARAM_HOLE.md), which leaves the
// IDELAYE2 and IDELAYCTRL out for the reason they should be left out, and lets
// the technology be declared truthfully so the IDDR appears.
//
// CHANGED 2026-08-03. The previous revision drove the core's AXI slave port from
// the same LFSR as its data pins, and read back adc_enable_i0 = 0 on silicon:
// the receive channel was never switched on, because nothing had ever written
// its registers. In a real system Linux does that. So the slave port is now
// connected to the PS through axi3_to_lite, and the registers are reachable
// from userspace with devmem at 0x4000_0000.
//
// Decode: 0x4000_0000 + 0x0000..0xFFFF -> axi_ad9361
//         0x4001_0000 + 0x0..0xF       -> local status, answered in the fabric
// The local block exists so that a failure can be localised: if 0x40010000
// reads back its magic and 0x40000000 does not read 0x000A0300, the bridge is
// fine and the core is not.
//
// EMIO in: [15:0] 0x47C0 anchor | [39:16] corr | [47:40] count | [48] adc_valid seen
module ps7_ad9361_axi;
    localparam W=16, ACC=24, N=63, AW=6;
    wire [3:0] FCLKCLK, FCLKRESETN;
    wire [63:0] gpio_o, gpio_i, gpio_t;
    wire clk = FCLKCLK[0];
    wire rst = ~FCLKRESETN[0] | gpio_o[0];
    reg [63:0] lfsr = 64'hA5A5_1234_DEAD_BEEF;
    always @(posedge clk) if (rst) lfsr <= 64'hA5A5_1234_DEAD_BEEF;
        else lfsr <= {lfsr[62:0], lfsr[63]^lfsr[62]^lfsr[60]^lfsr[59]};

    // Stimulus for the vendor bus. The LFSR is kept for the pins that only need
    // to be tied to something, but the three signals the receive protocol
    // actually reads are now driven properly:
    //
    //   rx_clk_in   a clean divide-by-two, 50% duty. An LFSR bit is not a clock:
    //               it holds its value for runs of several cycles and has no
    //               duty cycle to speak of.
    //   rx_frame_in a square wave at half the bus clock. Held low it gives
    //               frame 2'b00 forever, and the delineation case at
    //               axi_ad9361_cmos_if.v:225 then writes only adc_data_p[47:24]
    //               while [23:0] -- where channel I0 lives -- holds its reset
    //               value. Continuous valid with permanently zero I0 is exactly
    //               what the previous build measured. The frame must alternate:
    //               one bus period at 2'b11 writes the low half, the next at
    //               2'b00 latches the high half and asserts valid.
    //   rx_data_in  a counter, so every sample is known in advance and the
    //               correlation result can be predicted rather than admired.
    reg rxclk = 1'b0;
    always @(posedge clk) rxclk <= ~rxclk;
    reg rxframe = 1'b0;
    always @(posedge clk) if (rxclk) rxframe <= ~rxframe;
    // Two stimuli, selected from AXI at 0x40010028:
    //   bit 0 = 0  counter. Steps by one per clk, which after the vendor path's
    //              decimation becomes a ramp of step 4 -- fine for proving the
    //              plumbing, but it spans 252 of the bus's 4096 codes and never
    //              changes sign, so it leaves the adder tree's carries untested.
    //   bit 0 = 1  maximal-length 12-bit LFSR. Covers the full bus range, and
    //              with the core's sign-extension bit set it changes sign
    //              inside the 63-tap window, which is what makes carries
    //              propagate through the whole reduction.
    //   bit 1 = 1  reload the seed on arming, so two captures should be
    //              identical. Whether they actually are is a real question about
    //              this harness, not a formality: the sampling phase between the
    //              arm pulse and the frame is not obviously deterministic.
    //   mode 2    the tap sequence itself, at full scale. corr = sum tp[i]*xr[i]
    //             is maximised when xr[i] carries +2047 wherever tp[i] is +1 and
    //             -2047 wherever it is -1, so feeding the correlator its own
    //             matched sequence must produce 63 * 2047 = 128961 once every 63
    //             samples. That is the accumulator's real limit and it is also
    //             the function a despreader exists to perform, so it tests the
    //             arithmetic and demonstrates the purpose in the same capture.
    //
    // The vendor path decimates by exactly four -- measured, every one of the 63
    // intervals in the ramp capture stepped by 4 -- so the PN index advances
    // once per four clocks to put consecutive chips on consecutive samples.
    reg [11:0] stim = 12'd1;
    wire [11:0] stim_lfsr = {stim[10:0], stim[11]^stim[10]^stim[9]^stim[3]};
    reg [1:0] arm_edge = 2'b00;
    always @(posedge clk) arm_edge <= {arm_edge[0], cap_arm};
    wire arm_rise_clk = arm_edge[0] & ~arm_edge[1];

    reg [5:0] pn_idx = 6'd0;
    reg [1:0] div4 = 2'd0;
    // Reversed relative to the tap order, and that is not cosmetic. After 63
    // samples xr[i] holds the sample from i steps ago, so xr[i] = in[62-i]. For
    // xr[i] to carry tp[i]'s sign -- which is what makes every term add rather
    // than cancel -- the chip emitted at step k must be tp[62-k].
    wire [5:0] pn_rev = 6'd62 - pn_idx;
    wire pn_bit = pn_rev[0] ^ pn_rev[2] ^ pn_rev[4];
    wire [11:0] pn_chip = pn_bit ? 12'h7FF : 12'h801;   // +2047 / -2047, sign-extended by the core
    // capture start, brought back from the bus-clock domain. lclk is derived
    // from clk, so this crossing has a fixed phase rather than an arbitrary one.
    reg [1:0] go_sync = 2'b00;
    always @(posedge clk) go_sync <= {go_sync[0], cap_go};
    wire go_rise_clk = go_sync[0] & ~go_sync[1];

    always @(posedge clk) begin
        if (arm_rise_clk && stim_reseed) begin
            stim <= 12'd1; pn_idx <= 6'd0; div4 <= 2'd0;
        end else if (go_rise_clk) begin
            pn_idx <= 6'd0; div4 <= 2'd0;
        end else begin
            stim <= stim_sel[0] ? stim_lfsr : stim + 1'b1;
            div4 <= div4 + 1'b1;
            if (div4 == 2'd3) pn_idx <= (pn_idx == 6'd62) ? 6'd0 : pn_idx + 1'b1;
        end
    end
    wire [11:0] stim_out = (stim_sel == 2'd2) ? pn_chip : stim;
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
    // ---- PS7 M_AXI_GP0 -> AXI4-Lite ----
    wire [11:0] gp_awid, gp_arid; wire [31:0] gp_awaddr, gp_araddr, gp_wdata;
    wire [3:0]  gp_awlen, gp_arlen, gp_wstrb;
    wire gp_awvalid, gp_wvalid, gp_wlast, gp_bready, gp_arvalid, gp_rready;
    wire gp_awready, gp_wready, gp_bvalid, gp_arready, gp_rvalid, gp_rlast;
    wire [1:0] gp_bresp, gp_rresp; wire [31:0] gp_rdata;
    wire [11:0] gp_bid, gp_rid;
    wire m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
    wire [31:0] m_awaddr, m_wdata, m_araddr; wire [3:0] m_wstrb;

    wire m_awready, m_wready, m_bvalid, m_arready, m_rvalid;
    wire [1:0] m_bresp, m_rresp; wire [31:0] m_rdata;

    // address decode: bit 16 picks the local block over the vendor core
    wire sel_loc_w = m_awaddr[16];
    wire sel_loc_r = m_araddr[16];

    wire        core_awready, core_wready, core_bvalid, core_arready, core_rvalid;
    wire [1:0]  core_bresp, core_rresp; wire [31:0] core_rdata;

    // local status block: always ready, one-cycle response
    reg loc_bvalid = 0, loc_rvalid = 0; reg [31:0] loc_rdata = 0;
    // Deterministic capture. Sampling a free-running stream over AXI gives a
    // value that cannot be predicted, only admired. Arming resets the
    // correlator and records exactly 64 input samples and 64 of its outputs,
    // then freezes -- so the result is a function of the stimulus and can be
    // compared with the software model rather than eyeballed.
    reg cap_arm = 1'b0;
    reg [1:0] stim_sel = 2'd0;   // 0 counter, 1 LFSR, 2 matched PN
    reg stim_reseed = 1'b0;   // reload the seed when armed
    reg cap_align   = 1'b0;   // start on a frame boundary, not on the write
    wire loc_awready = sel_loc_w & m_awvalid & ~loc_bvalid;
    wire loc_wready  = sel_loc_w & m_wvalid  & ~loc_bvalid;
    wire loc_arready = sel_loc_r & m_arvalid & ~loc_rvalid;

    assign m_awready  = sel_loc_w ? loc_awready : core_awready;
    assign m_wready   = sel_loc_w ? loc_wready  : core_wready;
    assign m_bvalid   = sel_loc_w ? loc_bvalid  : core_bvalid;
    assign m_bresp    = sel_loc_w ? 2'b00       : core_bresp;
    assign m_arready  = sel_loc_r ? loc_arready : core_arready;
    assign m_rvalid   = sel_loc_r ? loc_rvalid  : core_rvalid;
    assign m_rdata    = sel_loc_r ? loc_rdata   : core_rdata;
    assign m_rresp    = sel_loc_r ? 2'b00       : core_rresp;

    axi3_to_lite #(.TIMEOUT(1024)) u_bridge (
        .clk(clk), .rstn(FCLKRESETN[0]),
        .s_awid(gp_awid), .s_awaddr(gp_awaddr), .s_awlen(gp_awlen),
        .s_awvalid(gp_awvalid), .s_awready(gp_awready),
        .s_wdata(gp_wdata), .s_wstrb(gp_wstrb), .s_wlast(gp_wlast),
        .s_wvalid(gp_wvalid), .s_wready(gp_wready),
        .s_bid(gp_bid), .s_bresp(gp_bresp), .s_bvalid(gp_bvalid), .s_bready(gp_bready),
        .s_arid(gp_arid), .s_araddr(gp_araddr), .s_arlen(gp_arlen),
        .s_arvalid(gp_arvalid), .s_arready(gp_arready),
        .s_rid(gp_rid), .s_rdata(gp_rdata), .s_rresp(gp_rresp),
        .s_rlast(gp_rlast), .s_rvalid(gp_rvalid), .s_rready(gp_rready),
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bvalid(m_bvalid), .m_bresp(m_bresp), .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid), .m_rready(m_rready));

    wire [31:0] o_up_dac_gpio_out;
    wire [31:0] o_up_adc_gpio_out;

    axi_ad9361 #(.FPGA_TECHNOLOGY(1), .IODELAY_CTRL(0), .CMOS_OR_LVDS_N(1)) u_rx (
        .rx_clk_in_p (lfsr[0]),
        .rx_clk_in_n (lfsr[1]),
        .rx_frame_in_p (lfsr[2]),
        .rx_frame_in_n (lfsr[3]),
        .rx_data_in_p (lfsr[5:0]),
        .rx_data_in_n (lfsr[5:0]),
        .rx_clk_in (rxclk),
        .rx_frame_in (rxframe),
        .rx_data_in (stim_out),
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
        .s_axi_aresetn (FCLKRESETN[0]),
        .s_axi_awvalid (m_awvalid & ~sel_loc_w),
        .s_axi_awaddr (m_awaddr[15:0]),
        .s_axi_awprot (3'b000),
        .s_axi_wvalid (m_wvalid & ~sel_loc_w),
        .s_axi_wdata (m_wdata),
        .s_axi_wstrb (m_wstrb),
        .s_axi_bready (m_bready),
        .s_axi_arvalid (m_arvalid & ~sel_loc_r),
        .s_axi_araddr (m_araddr[15:0]),
        .s_axi_arprot (3'b000),
        .s_axi_rready (m_rready),
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
        .s_axi_awready (core_awready),
        .s_axi_wready (core_wready),
        .s_axi_bvalid (core_bvalid),
        .s_axi_bresp (core_bresp),
        .s_axi_arready (core_arready),
        .s_axi_rvalid (core_rvalid),
        .s_axi_rdata (core_rdata),
        .s_axi_rresp (core_rresp),
        .up_dac_gpio_out (o_up_dac_gpio_out),
        .up_adc_gpio_out (o_up_adc_gpio_out)
    );

    // ---- our core, in the receive path ----
    wire lclk = o_l_clk;
    wire signed [ACC-1:0] m_data; wire m_valid;
    reg [AW-1:0] tap_addr = 0; reg tap_wr = 0; reg taps_done = 0;
    reg [1:0] arm_sync = 2'b00;
    always @(posedge lclk) arm_sync <= {arm_sync[0], cap_arm};
    wire arm_pulse = arm_sync[0] & ~arm_sync[1];

    always @(posedge lclk) begin
        if (rst || arm_pulse) begin tap_addr<=0; tap_wr<=0; taps_done<=0; end
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

    // 128 deep, not 64, and the reason is the peak. The shift register is 63
    // long, so with a 64-sample capture only the very last output has a full
    // window -- everything before it is still filling. A matched-filter peak
    // then has to land on exactly that one sample, which needs the stimulus
    // phase to survive a clock-domain crossing, and it did not: the measured
    // out[63] came to 37 * 2047, the signature of a shifted window. With 128
    // samples the first half warms the register and every output in the second
    // half has a full window, so a 63-periodic input must put the peak in one
    // of them regardless of phase.
    reg [15:0] in_mem  [0:127];  // full width: the correlator sees all 16 bits
    reg [23:0] out_mem [0:127];
    reg [7:0]  in_idx = 0, out_idx = 0;
    reg        capturing = 0;
    reg        pending = 0;
    reg        cap_go = 0;
    always @(posedge lclk) begin
        if (rst) begin capturing<=0; in_idx<=0; out_idx<=0; pending<=0; cap_go<=0; end
        else if (arm_pulse) begin
            in_idx<=0; out_idx<=0; cap_go<=1'b0;
            // Without alignment the capture begins wherever the software write
            // landed, and two reseeded runs then sample different slices of the
            // same sequence -- measured, all 64 samples differed. Waiting for a
            // known frame code makes the start deterministic.
            if (cap_align) begin pending<=1'b1; capturing<=1'b0; end
            else            begin pending<=1'b0; capturing<=1'b1; end
        end
        else if (pending && taps_done) begin
            if ({fr_p, fr_n} == 2'b01) begin
                pending <= 1'b0; capturing <= 1'b1; cap_go <= 1'b1;
            end
        end
        else if (capturing && taps_done) begin
            if (o_adc_valid_i0 && !in_idx[7]) begin
                in_mem[in_idx[6:0]] <= o_adc_data_i0;
                in_idx <= in_idx + 1'b1;
            end
            if (m_valid && !out_idx[7]) begin
                out_mem[out_idx[6:0]] <= m_data;
                out_idx <= out_idx + 1'b1;
            end
            if (in_idx[7] && out_idx[7]) capturing <= 1'b0;
        end
    end

    reg signed [ACC-1:0] corr_hold = 0; reg [7:0] cnt = 0; reg saw_valid = 0;
    always @(posedge lclk) begin
        if (rst) begin corr_hold<=0; cnt<=0; saw_valid<=0; end
        else begin
            if (m_valid) corr_hold <= m_data;
            if (o_adc_valid_i0) begin cnt <= cnt + 8'd1; saw_valid <= 1'b1; end
        end
    end
    // diagnostics: is the vendor core's receive channel actually enabled?
    // adc_enable_i0 comes from the core's control registers, which in a real
    // system Linux writes over AXI. Here the AXI side is LFSR noise, so the
    // channel may simply be off -- which would explain zero data far better
    // than anything wrong with the correlator.
    reg [11:0] last_sample = 0;
    reg any_nonzero = 0;
    reg [15:0] lclk_beats = 0;
    always @(posedge lclk) lclk_beats <= lclk_beats + 1'b1;
    // The vendor's frame capture is internal to axi_ad9361_cmos_if, so mirror it
    // here with the same two-edge sampling and record which of the four codes
    // occur. A stimulus whose phase is wrong then reads as "only codes 0 and 3"
    // instead of as an unexplained zero, and the alternation the protocol needs
    // is codes 3 and 0 in turn -- which is what this must show.
    reg fr_p = 1'b0, fr_n = 1'b0;
    always @(posedge lclk) fr_p <= rxframe;
    always @(negedge lclk) fr_n <= rxframe;
    reg [3:0] frame_seen = 4'd0;
    always @(posedge lclk) frame_seen <= frame_seen | (4'd1 << {fr_p, fr_n});
    always @(posedge lclk) if (!rst) begin
        if (o_adc_valid_i0) begin
            last_sample <= o_adc_data_i0[11:0];
            if (|o_adc_data_i0) any_nonzero <= 1'b1;
        end
    end
    // 16 anchor + 24 corr + 8 count + 4 flags + 12 sample = 64
    assign gpio_i = {last_sample, any_nonzero, o_adc_r1_mode, o_adc_enable_i0,
                     saw_valid, cnt, corr_hold, 16'h47C0};

    // local status block. Reads answer in one cycle and never stall, so a read
    // of 0x40010000 that fails cannot be blamed on the bridge's timeout path.
    reg [23:0] corr_seen = 0;
    always @(posedge clk) begin
        if (!FCLKRESETN[0]) begin loc_bvalid <= 0; loc_rvalid <= 0; end
        else begin
            if (loc_wready) begin
                loc_bvalid <= 1'b1;
                if (m_awaddr[9:2] == 8'h08) cap_arm <= m_wdata[0];   // 0x40010020
                if (m_awaddr[9:2] == 8'h0A) begin                    // 0x40010028
                    stim_sel    <= m_wdata[1:0];
                    stim_reseed <= m_wdata[2];
                    cap_align   <= m_wdata[3];
                end
            end
            else if (loc_bvalid && m_bready) loc_bvalid <= 1'b0;
            if (loc_arready) begin
                loc_rvalid <= 1'b1;
                if (m_araddr[11:10] == 2'b01)      loc_rdata <= {16'd0, in_mem [m_araddr[9:2]]};
                else if (m_araddr[11:10] == 2'b10) loc_rdata <= { 8'd0, out_mem[m_araddr[9:2]]};
                else case (m_araddr[7:2])
                    6'h0: loc_rdata <= 32'h5A5A_47C0;                 // bridge alive
                    6'h1: loc_rdata <= {8'd0, corr_hold};             // correlator output
                    6'h2: loc_rdata <= {24'd0, cnt};                  // samples counted
                    6'h3: loc_rdata <= {28'd0, any_nonzero, o_adc_r1_mode,
                                        o_adc_enable_i0, saw_valid};  // core state
                    6'h4: loc_rdata <= {20'd0, last_sample};          // last sample
                    6'h5: loc_rdata <= {16'd0, lclk_beats};          // does l_clk run?
                    6'h6: loc_rdata <= {28'd0, frame_seen};          // frame codes observed
                    6'h8: loc_rdata <= {31'd0, cap_arm};             // capture arm
                    6'h9: loc_rdata <= {14'd0, capturing, out_idx, 1'd0, in_idx};  // idx now 8 bits each
                    6'hA: loc_rdata <= {28'd0, cap_align, stim_reseed, stim_sel};
                    default: loc_rdata <= 32'h0000_0000;
                endcase
            end else if (loc_rvalid && m_rready) loc_rvalid <= 1'b0;
        end
    end

    PS7 ps7_i (.FCLKCLK(FCLKCLK), .FCLKRESETN(FCLKRESETN),
               .EMIOGPIOO(gpio_o), .EMIOGPIOI(gpio_i), .EMIOGPIOTN(gpio_t),
               .MAXIGP0ACLK(clk),
               .MAXIGP0AWID(gp_awid),     .MAXIGP0AWADDR(gp_awaddr),
               .MAXIGP0AWLEN(gp_awlen),   .MAXIGP0AWVALID(gp_awvalid),
               .MAXIGP0AWREADY(gp_awready),
               .MAXIGP0WDATA(gp_wdata),   .MAXIGP0WSTRB(gp_wstrb),
               .MAXIGP0WLAST(gp_wlast),   .MAXIGP0WVALID(gp_wvalid),
               .MAXIGP0WREADY(gp_wready),
               .MAXIGP0BID(gp_bid),       .MAXIGP0BRESP(gp_bresp),
               .MAXIGP0BVALID(gp_bvalid), .MAXIGP0BREADY(gp_bready),
               .MAXIGP0ARID(gp_arid),     .MAXIGP0ARADDR(gp_araddr),
               .MAXIGP0ARLEN(gp_arlen),   .MAXIGP0ARVALID(gp_arvalid),
               .MAXIGP0ARREADY(gp_arready),
               .MAXIGP0RID(gp_rid),       .MAXIGP0RDATA(gp_rdata),
               .MAXIGP0RRESP(gp_rresp),   .MAXIGP0RLAST(gp_rlast),
               .MAXIGP0RVALID(gp_rvalid), .MAXIGP0RREADY(gp_rready));
endmodule
`default_nettype wire
