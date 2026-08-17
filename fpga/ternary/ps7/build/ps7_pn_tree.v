`default_nettype none
// The 63-tap PN despreader in the PL, fed real captured samples by Linux.
//
// ps7_corr proved the 8-tap matched filter in silicon: 256 of 256 outputs
// bit-identical to the software reference on a real over-the-air capture. This
// is the same experiment one order of magnitude up -- 63 taps instead of 8, a
// 24-bit accumulator instead of 20 -- because eight taps is a primitive and 63
// is the length the DSSS link actually despreads with.
//
// ZERO external ports, as with ps7_probe and ps7_corr: everything crosses over
// EMIO GPIO, so nothing here can touch a board pin or the AD9361 front end, and
// recovery from a bad load is `reboot`.
//
// EMIO out (PS -> PL):
//   [15:0]  sample, signed 16-bit, native ADC width
//   [16]    strobe   toggle; one sample is ingested on every change
//   [17]    rst      clears the delay line
//   [18]    c_wr     tap write strobe
//   [24:19] c_addr   tap index 0..62  (6 bits, up from 3)
//   [26:25] c_data   tap code: 01 -> +1, 10 -> -1, else 0
//
// EMIO in (PL -> PS):
//   [15:0]  0x47C0   anchor: proves this bitstream, not the vendor's, is live
//   [39:16] corr     24-bit signed correlator output (up from 20)
//   [47:40] count    ingested-sample counter, wraps at 256
//   [48]    ack      follows strobe once the sample has been taken
//
// Note for the host side: corr now spans EMIO[39:16], so it straddles the two
// Zynq GPIO banks by a full byte rather than a nibble. Bank 2 (0xE000A068) is
// EMIO[31:0]; bank 3 (0xE000A06C) is EMIO[63:32]. Reassemble as
//   corr = ((bank3 & 0xFF) << 16) | (bank2 >> 16)
// and sign-extend from bit 23. Reading bank 2 alone silently truncates.
//
module ps7_pn_tree;
    localparam integer N   = 63;
    localparam integer W   = 16;
    localparam integer ACC = 24;
    localparam integer AW  = 6;

    wire [3:0]  FCLKCLK;
    wire [3:0]  FCLKRESETN;
    wire [63:0] gpio_o;
    wire [63:0] gpio_i;
    wire [63:0] gpio_t;

    wire clk   = FCLKCLK[0];
    wire rst_n = FCLKRESETN[0];

    // ---- EMIO is asynchronous to FCLK: synchronise before edge detection ----
    reg [1:0] strobe_sync, cwr_sync, rst_sync;
    always @(posedge clk) begin
        strobe_sync <= {strobe_sync[0], gpio_o[16]};
        cwr_sync    <= {cwr_sync[0],    gpio_o[18]};
        rst_sync    <= {rst_sync[0],    gpio_o[17]};
    end

    reg strobe_d;
    always @(posedge clk) strobe_d <= strobe_sync[1];
    wire s_valid = strobe_sync[1] ^ strobe_d;   // one pulse per toggle

    reg cwr_d;
    always @(posedge clk) cwr_d <= cwr_sync[1];
    wire c_wr = cwr_sync[1] & ~cwr_d;           // rising edge only

    wire core_rst = ~rst_n | rst_sync[1];

    // ---- the project's own 63-tap despreader, unmodified ----
    wire                  m_valid;
    wire signed [ACC-1:0] m_data;

    tern_corr_pn_tree #(.N(N), .W(W), .ACC(ACC), .AW(AW)) u_pn (
        .clk     (clk),
        .rst     (core_rst),
        .s_valid (s_valid),
        .s_data  (gpio_o[15:0]),
        .c_wr    (c_wr),
        .c_addr  (gpio_o[24:19]),
        .c_data  (gpio_o[26:25]),
        .m_valid (m_valid),
        .m_data  (m_data)
    );

    // ---- hold the last result and count what went in ----
    reg signed [ACC-1:0] corr_hold;
    reg [7:0]            count;
    reg                  ack;
    always @(posedge clk) begin
        if (core_rst) begin
            corr_hold <= 0;
            count     <= 8'd0;
            ack       <= 1'b0;
        end else begin
            if (m_valid) corr_hold <= m_data;
            if (s_valid) begin
                count <= count + 8'd1;
                ack   <= strobe_sync[1];
            end
        end
    end

    assign gpio_i = {15'd0, ack, count, corr_hold, 16'h47C0};

    PS7 ps7_i (
        .FCLKCLK    (FCLKCLK),
        .FCLKRESETN (FCLKRESETN),
        .EMIOGPIOO  (gpio_o),
        .EMIOGPIOI  (gpio_i),
        .EMIOGPIOTN (gpio_t)
    );
endmodule
`default_nettype wire
