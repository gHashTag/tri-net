`default_nettype none
// ASU_TP_SOM node in one Zynq-7020, open flow. Balyberdin's module = compute + SSI
// network + I/O on one chip. Here: PS7 hard block (compute + control) drives, via
// EMIO GPIO (the SSI virtual-channel interface, Linux /sys/class/gpio), the operands,
// weights and the arrival strobe of an IEC 61499 ternary function block; clkrec
// recovers a deterministic clock whose ticks are the block's firing events; the PS
// reads back the result, the event and the FIFO fill. One deterministic IEC 61499
// node -- recovered timing + firing-gated ternary compute -- as a loadable bitstream.
module asutp_som (output wire led);
    wire [3:0]  FCLKCLK, FCLKRESETN;
    wire [63:0] gpio_o, gpio_i, gpio_t;
    wire clk   = FCLKCLK[0];
    wire rst   = ~FCLKRESETN[0];

    // PS -> PL over EMIO (his "load the function-block software" + SSI channel):
    wire        arrive = gpio_o[0];        // SSI sample-arrival strobe
    wire [3:0]  valid  = gpio_o[7:4];      // per-operand data-present (his no-data = !valid)
    wire [31:0] xin    = gpio_o[39:8];     // 4x8 signed operands
    wire [7:0]  wgt    = gpio_o[47:40];    // 4x2 ternary weights

    // deterministic clock recovery from the SSI arrivals
    wire drain; wire [9:0] fill; wire signed [28:0] inc_now;
    clkrec #(.PW(28),.FW(10)) cr (.clk(clk),.rst(rst),.arrive(arrive),
        .inc_base(28'd268435),.drain(drain),.fill(fill),.inc_now(inc_now));

    // IEC 61499 function block: fires on the recovered tick when all operands present
    wire cnf; wire signed [11:0] y;
    fb61499 #(.NO(4),.W(8)) fb (.clk(clk),.rst(rst),.req(drain),.valid(valid),
        .xin(xin),.wgt(wgt),.cnf(cnf),.y(y));

    // PL -> PS readback: result y, event cnf, drain tick, FIFO fill
    assign gpio_i = {40'b0, cnf, drain, fill, y};

    reg [23:0] hb; always @(posedge clk) hb <= rst ? 24'd0 : hb + 1'b1;
    assign led = hb[23] ^ cnf;

    PS7 ps7 (.FCLKCLK(FCLKCLK), .FCLKRESETN(FCLKRESETN),
             .EMIOGPIOO(gpio_o), .EMIOGPIOI(gpio_i), .EMIOGPIOTN(gpio_t));
endmodule
`default_nettype wire
