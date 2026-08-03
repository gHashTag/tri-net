// Minimal probe: can the open flow place and route a differential input buffer?
// IBUFDS is the gate on any LVDS clock or data pair, which every AD9361
// datapath needs. No IBUFDS appears anywhere in this project's RTL.
module prim_ibufds (
    input  wire clk_p,
    input  wire clk_n,
    output wire led
);
    wire clk;
    IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("TRUE"), .IOSTANDARD("LVDS_25"))
        u_ibufds (.I(clk_p), .IB(clk_n), .O(clk));
    reg [23:0] cnt = 24'd0;
    always @(posedge clk) cnt <= cnt + 24'd1;
    assign led = cnt[23];
endmodule
