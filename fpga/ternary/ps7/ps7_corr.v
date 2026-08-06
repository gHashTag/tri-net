`default_nettype none
// Own RTL in the radio path: the ternary matched filter running in the PL,
// fed with real over-the-air samples by Linux on the PS.
//
// Until now the radio results came from the vendor bitstream plus host-side or
// ARM-side DSP: correct, but none of the project's own RTL was in the signal
// path. This design puts `tern_corr8_stream` -- the project's zero-DSP ternary
// correlator -- into the fabric and lets the PS push captured samples through
// it, then compares the fabric's answer with the software reference on the same
// samples. Same capture, two independent implementations, compared bit for bit.
//
// ZERO external ports, as with ps7_probe: everything crosses over EMIO GPIO, so
// nothing here can touch a board pin or the AD9361 front end.
//
// EMIO out (PS -> PL):
//   [15:0]  sample, signed 16-bit, native ADC width
//   [16]    strobe   toggle; one sample is ingested on every change
//   [17]    rst      clears the delay line
//   [18]    c_wr     tap write strobe, level, sampled with c_addr/c_data
//   [21:19] c_addr   tap index 0..7
//   [23:22] c_data   tap code: 01 -> +1, 10 -> -1, else 0
//
// EMIO in (PL -> PS):
//   [15:0]  0x47C0   anchor: proves this bitstream, not the vendor's, is live
//   [35:16] corr     20-bit signed correlator output
//   [43:36] count    ingested-sample counter, wraps at 256
//   [44]    ack      follows strobe once the sample has been taken
//
module ps7_corr;
    localparam integer W   = 16;
    localparam integer ACC = 20;

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

    // ---- the project's own correlator, unmodified ----
    wire                  m_valid;
    wire signed [ACC-1:0] m_data;

    tern_corr8_stream #(.W(W), .ACC(ACC)) u_corr (
        .clk     (clk),
        .rst     (core_rst),
        .s_valid (s_valid),
        .s_data  (gpio_o[15:0]),
        .c_wr    (c_wr),
        .c_addr  (gpio_o[21:19]),
        .c_data  (gpio_o[23:22]),
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

    assign gpio_i = {19'd0, ack, count, corr_hold, 16'h47C0};

    PS7 ps7_i (
        .FCLKCLK    (FCLKCLK),
        .FCLKRESETN (FCLKRESETN),
        .EMIOGPIOO  (gpio_o),
        .EMIOGPIOI  (gpio_i),
        .EMIOGPIOTN (gpio_t)
    );
endmodule
`default_nettype wire
