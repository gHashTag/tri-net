`default_nettype none
module clkrec_top(input wire clk, input wire rst, input wire arrive,
                  output wire drain, output wire busy);
    wire [9:0] fill; wire signed [28:0] inc_now;
    clkrec #(.PW(28),.FW(10)) u(.clk(clk),.rst(rst),.arrive(arrive),
        .inc_base(28'd268435),.drain(drain),.fill(fill),.inc_now(inc_now));
    assign busy = (|fill) ^ inc_now[0];  // keep fill/inc_now alive, 1-bit status out
endmodule
`default_nettype wire
