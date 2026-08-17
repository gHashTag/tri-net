`default_nettype none
// The 63-tap despreader self-tested AT FULL FABRIC RATE, with no processor in
// the loop.
//
// Every silicon result so far -- 8 taps and 63 taps, both 256 of 256 bit-exact
// -- was obtained by pushing one sample per `devmem` write, which is a few
// hundred samples per second. That proves the arithmetic and says nothing at
// all about throughput, and this project has never quoted a throughput number.
// This design closes that gap: samples come from a ROM in the fabric, one per
// clock, straight into the correlator, and the comparison against the expected
// values happens in the fabric too. The PS only starts it and reads the verdict.
//
// What it measures: whether the correlator sustains one sample per clock at the
// frequency the design closes timing at, and whether every output is still
// bit-identical to the software reference when it does.
//
// ZERO external ports, as with every design in this directory: everything
// crosses over EMIO GPIO, nothing can touch a board pin or the AD9361 front
// end, and recovery from a bad load is `reboot`.
//
// EMIO out (PS -> PL):
//   [0]     go       level; rising edge starts one full pass over the ROM
//   [1]     rst      clears the run
//
// EMIO in (PL -> PS):
//   [15:0]  0x47C0   anchor
//   [16]    busy
//   [17]    done
//   [27:18] errors   mismatches this pass, saturating at 1023
//   [37:28] nchecked outputs compared this pass
//   [61:38] cycles   clocks the pass took, which is the throughput number
//
module ps7_speed;
    localparam integer W   = 16;
    localparam integer ACC = 24;
    localparam integer N   = 63;
    localparam integer AW  = 6;

    wire [3:0]  FCLKCLK;
    wire [3:0]  FCLKRESETN;
    wire [63:0] gpio_o;
    wire [63:0] gpio_i;
    wire [63:0] gpio_t;

    wire clk   = FCLKCLK[0];
    wire rst_n = FCLKRESETN[0];

    `include "speed_rom.vh"

    // ---- EMIO is asynchronous to FCLK ----
    reg [1:0] go_sync, rst_sync;
    always @(posedge clk) begin
        go_sync  <= {go_sync[0],  gpio_o[0]};
        rst_sync <= {rst_sync[0], gpio_o[1]};
    end
    reg go_d;
    always @(posedge clk) go_d <= go_sync[1];
    wire go_edge = go_sync[1] & ~go_d;
    // A start request that arrives while the taps are still loading used to be
    // dropped, and because `go` is a level the host never learns it was lost --
    // it simply waits forever on a `done` that will not come. Latching the
    // request and honouring it once the taps are in removes the window
    // entirely. On the board the host raises `go` long after boot, so this was
    // never seen there; it was found by starting the design in simulation the
    // way a script would, immediately.
    reg go_pending;
    always @(posedge clk) begin
        if (core_rst) go_pending <= 1'b0;
        else if (go_edge && !taps_done) go_pending <= 1'b1;
        else if (taps_done) go_pending <= 1'b0;
    end
    wire go_pulse = (go_edge & taps_done) | (go_pending & taps_done);
    wire core_rst = ~rst_n | rst_sync[1];

    // ---- tap load: drive the whole vector in at reset, no host involvement ----
    reg [AW-1:0] tap_addr;
    reg          tap_wr;
    reg          taps_done;
    always @(posedge clk) begin
        if (core_rst) begin
            tap_addr  <= 0;
            tap_wr    <= 1'b0;
            taps_done <= 1'b0;
        end else if (!taps_done) begin
            tap_wr <= 1'b1;
            if (tap_wr) begin
                if (tap_addr == N-1) begin
                    taps_done <= 1'b1;
                    tap_wr    <= 1'b0;
                end else begin
                    tap_addr <= tap_addr + 1'b1;
                end
            end
        end else begin
            tap_wr <= 1'b0;
        end
    end
    wire [1:0] tap_code = TAP_CODES[tap_addr*2 +: 2];

    // ---- the run: one sample per clock, straight through ----
    reg [8:0]  rd_addr;      // 0..256
    reg        running;
    reg        done;
    reg [9:0]  errors;
    reg [9:0]  nchecked;
    reg [23:0] cycles;

    // Feed ROM_N+1 samples. The extra one is a throwaway: m_data latches `corr`
    // computed BEFORE the new sample shifts in, so the correlation through the
    // last real sample only becomes visible on one more m_valid. Same pipeline
    // offset that the host-side harness has to honour -- see corr_stream.c.
    wire feeding = running && (rd_addr <= ROM_N);
    wire signed [W-1:0] s_data =
        (running && rd_addr < ROM_N) ? sample_rom[rd_addr[7:0]] : {W{1'b0}};

    wire                  m_valid;
    wire signed [ACC-1:0] m_data;

    tern_corr_pn_tree #(.N(N), .W(W), .ACC(ACC), .AW(AW)) u_pn (
        .clk     (clk),
        .rst     (core_rst),
        .s_valid (feeding),
        .s_data  (s_data),
        .c_wr    (tap_wr),
        .c_addr  (tap_addr),
        .c_data  (tap_code),
        .m_valid (m_valid),
        .m_data  (m_data)
    );

    // The correlator answers one clock behind the sample that produced it. The
    // FIRST m_valid therefore carries the correlation of an empty delay line,
    // not gold_rom[0]. Discard it, then compare pulse k+1 against gold_rom[k].
    reg [8:0] chk_addr;
    reg       primed;

    always @(posedge clk) begin
        if (core_rst) begin
            rd_addr  <= 0;
            running  <= 1'b0;
            done     <= 1'b0;
            errors   <= 10'd0;
            nchecked <= 10'd0;
            cycles   <= 24'd0;
            chk_addr <= 0;
            primed   <= 1'b0;
        end else begin
            if (go_pulse && taps_done && !running) begin
                rd_addr  <= 0;
                chk_addr <= 0;
                errors   <= 10'd0;
                nchecked <= 10'd0;
                cycles   <= 24'd0;
                primed   <= 1'b0;
                running  <= 1'b1;
                done     <= 1'b0;
            end

            if (running) begin
                cycles <= cycles + 24'd1;
                if (rd_addr <= ROM_N) rd_addr <= rd_addr + 1'b1;

                if (m_valid) begin
                    if (!primed) begin
                        primed <= 1'b1;          // discard the empty-line output
                    end else if (chk_addr < ROM_N) begin
                        if (m_data != gold_rom[chk_addr[7:0]] && errors != 10'd1023)
                            errors <= errors + 10'd1;
                        if (nchecked != 10'd1023) nchecked <= nchecked + 10'd1;
                        chk_addr <= chk_addr + 1'b1;
                        if (chk_addr == ROM_N-1) begin
                            running <= 1'b0;
                            done    <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    assign gpio_i = {2'd0, cycles, nchecked, errors, done, running, 16'h47C0};

    PS7 ps7_i (
        .FCLKCLK    (FCLKCLK),
        .FCLKRESETN (FCLKRESETN),
        .EMIOGPIOO  (gpio_o),
        .EMIOGPIOI  (gpio_i),
        .EMIOGPIOTN (gpio_t)
    );
endmodule
`default_nettype wire
