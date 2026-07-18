`default_nettype none
// Minimal PS-driven ternary peripheral on Zynq-7020, 100% open flow.
// The PS7 hard block gives the PL a clock (FCLKCLK[0]) and a 32-bit EMIO GPIO
// bus that Linux drives from /sys/class/gpio -- no custom AXI needed. The PS
// writes a test sample + a ternary weight over EMIOGPIOO; a sign-select MAC
// (the tri-net primitive) computes +x/-x/0 in ONE LUT-level, and the PS reads
// the result back over EMIOGPIOI. This is the whole "PS drives the ternary
// core on one chip" loop, minimal.
module ps7_tern (output wire led);
    wire [3:0] FCLKCLK;
    wire [3:0] FCLKRESETN;
    wire [63:0] gpio_o;      // PS -> PL
    wire [63:0] gpio_i;      // PL -> PS
    wire [63:0] gpio_t;      // tri-state (unused here)

    wire clk = FCLKCLK[0];
    wire rst_n = FCLKRESETN[0];

    // PS writes: gpio_o[7:0] = signed sample x, gpio_o[9:8] = ternary weight w
    wire signed [7:0] x = gpio_o[7:0];
    wire [1:0] w = gpio_o[9:8];

    // ternary sign-select MAC: 01->+x, 10->-x, else 0  (ZERO DSP)
    reg signed [8:0] y;
    always @(posedge clk) begin
        if (!rst_n) y <= 9'sd0;
        else case (w)
            2'b01:   y <= x;
            2'b10:   y <= -x;
            default: y <= 9'sd0;
        endcase
    end

    // PL -> PS: return the MAC result so Linux can read it back
    assign gpio_i = {{55{y[8]}}, y};

    // a heartbeat LED off the PS clock, proving FCLK reaches the fabric
    reg [23:0] cnt;
    always @(posedge clk) cnt <= (!rst_n) ? 24'd0 : cnt + 1'b1;
    assign led = cnt[23];

    PS7 ps7_i (
        .FCLKCLK      (FCLKCLK),
        .FCLKRESETN   (FCLKRESETN),
        .EMIOGPIOO    (gpio_o),
        .EMIOGPIOI    (gpio_i),
        .EMIOGPIOTN   (gpio_t)
    );
endmodule
`default_nettype wire
