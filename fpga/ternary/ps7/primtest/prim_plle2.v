module prim_plle2 (input wire clk_in, output wire led);
    wire clk_fb, clk_out, clk_outb;
    PLLE2_BASE #(.CLKIN1_PERIOD(10.0), .CLKFBOUT_MULT(10), .CLKOUT0_DIVIDE(10), .DIVCLK_DIVIDE(1))
      u_pll (.CLKIN1(clk_in), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
             .CLKOUT0(clk_out), .RST(1'b0), .PWRDWN(1'b0), .LOCKED());
    BUFG u_bufg (.I(clk_out), .O(clk_outb));
    reg [23:0] cnt = 24'd0;
    always @(posedge clk_outb) cnt <= cnt + 24'd1;
    assign led = cnt[23];
endmodule
