// BUFR + BUFIO: the regional clock buffers in ad_data_clk.v / ad_serdes_clk.v
module prim_bufr (input wire clk_p, input wire clk_n, output wire dout);
    wire ci, cr, cb;
    IBUFDS #(.IOSTANDARD("LVDS_25")) u_ib (.I(clk_p), .IB(clk_n), .O(ci));
    BUFIO u_bufio (.I(ci), .O(cb));
    BUFR #(.BUFR_DIVIDE("2")) u_bufr (.I(ci), .O(cr), .CE(1'b1), .CLR(1'b0));
    reg [7:0] c1 = 0, c2 = 0;
    always @(posedge cb) c1 <= c1 + 1;
    always @(posedge cr) c2 <= c2 + 1;
    assign dout = c1[7] ^ c2[7];
endmodule
