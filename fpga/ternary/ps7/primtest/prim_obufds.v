// OBUFDS + IBUFGDS: differential output, and the global-clock-capable input
module prim_obufds (input wire clk_p, input wire clk_n, output wire o_p, output wire o_n);
    wire c; IBUFGDS #(.IOSTANDARD("LVDS_25")) u_ib (.I(clk_p), .IB(clk_n), .O(c));
    reg [7:0] cnt = 0; always @(posedge c) cnt <= cnt + 1;
    OBUFDS #(.IOSTANDARD("LVDS_25")) u_ob (.I(cnt[7]), .O(o_p), .OB(o_n));
endmodule
