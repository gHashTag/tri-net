`default_nettype none

// tern_corr8_axi -- the ternary matched-filter demod as an AXI4-Lite peripheral,
// so the Zynq PS controls it and reads results over the same CSR aperture the
// t27 BitNet accelerator uses. This is the deployment bridge: on the P201Mini
// the PS writes the reference code and reads the correlation peak, while the
// sample stream comes straight off the AD9361 in the PL (the data plane never
// touches AXI-Lite -- control plane only).
//
// Register map (reuses the t27-generated axi_lite_slave, gen-axi-lite-slave):
//   reg_ctrl  (write, word 0x0): [15:0] eight 2-bit ternary taps, [16] load
//             pulse (0->1 latches the taps into the correlator), [17] clear peak
//   reg_status (read,  word 0x1): sign-extended running peak of the correlation
//
// The generated slave is the SSOT for the AXI handshake; this wrapper only wires
// our datapath onto its registers. Ternary correlator SSOT: t27 gfternary.
module tern_corr8_axi #(
    parameter integer W = 16, parameter integer ACC = 20
) (
    input  wire        clk,
    input  wire        rst_n,
    // AXI4-Lite (control plane)
    input  wire [7:0]  s_axi_awaddr,  input  wire s_axi_awvalid, output wire s_axi_awready,
    input  wire [31:0] s_axi_wdata,   input  wire [3:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,  output wire s_axi_wready,
    output wire [1:0]  s_axi_bresp,   output wire s_axi_bvalid, input wire s_axi_bready,
    input  wire [7:0]  s_axi_araddr,  input  wire s_axi_arvalid, output wire s_axi_arready,
    output wire [31:0] s_axi_rdata,   output wire [1:0] s_axi_rresp,
    output wire        s_axi_rvalid,  input  wire s_axi_rready,
    // sample stream (data plane, from the AD9361 in the PL)
    input  wire        s_valid,
    input  wire signed [W-1:0] s_data
);
    wire [31:0] reg_ctrl;
    reg  [31:0] reg_status;

    axi_lite_slave axi (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .reg_ctrl(reg_ctrl), .reg_status(reg_status),
        .reg_irq_en(), .reg_irq_stat(32'd0),
        .reg_num_layers(), .reg_neurons(), .reg_chunks(), .reg_threshold(),
        .reg_weight_addr(), .reg_input_addr(), .reg_output_addr(), .reg_cycles(64'd0)
    );

    // ---- tap loader: on the rising edge of reg_ctrl[16], walk the 8 taps into
    //      the correlator's config port over 8 clocks ----
    reg        prev_load;
    reg        loading;
    reg  [3:0] load_idx;
    reg  [15:0] tap_word;
    reg        c_wr;  reg [2:0] c_addr;  reg [1:0] c_data;
    wire       corr_rst = ~rst_n | reg_ctrl[17];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_load <= 1'b0; loading <= 1'b0; load_idx <= 4'd0;
            c_wr <= 1'b0; c_addr <= 3'd0; c_data <= 2'd0; tap_word <= 16'd0;
        end else begin
            prev_load <= reg_ctrl[16];
            c_wr <= 1'b0;
            if (reg_ctrl[16] & ~prev_load) begin      // rising edge of load
                loading  <= 1'b1; load_idx <= 4'd0; tap_word <= reg_ctrl[15:0];
            end else if (loading) begin
                c_wr   <= 1'b1;
                c_addr <= load_idx[2:0];
                c_data <= tap_word[load_idx*2 +: 2];
                if (load_idx == 4'd7) loading <= 1'b0;
                load_idx <= load_idx + 4'd1;
            end
        end
    end

    // ---- correlator ----
    wire        m_valid;
    wire signed [ACC-1:0] m_data;
    tern_corr8_stream #(.W(W), .ACC(ACC)) corr (
        .clk(clk), .rst(corr_rst),
        .s_valid(s_valid), .s_data(s_data),
        .c_wr(c_wr), .c_addr(c_addr), .c_data(c_data),
        .m_valid(m_valid), .m_data(m_data)
    );

    // ---- peak-hold, published to reg_status (sign-extended 20 -> 32) ----
    // Track m_data every cycle, NOT gated on m_valid: the aligned correlation
    // lands one clock after the last valid sample (pipeline flush), so a
    // m_valid gate would miss the true peak. Idle m_data holds its last value,
    // which never exceeds a real peak.
    reg signed [ACC-1:0] peak;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin peak <= 0; reg_status <= 32'd0; end
        else begin
            if (corr_rst) peak <= 0;
            else if (m_data > peak) peak <= m_data;
            reg_status <= {{(32-ACC){peak[ACC-1]}}, peak};
        end
    end
endmodule

`default_nettype wire
