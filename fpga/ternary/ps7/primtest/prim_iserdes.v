module prim_iserdes (input wire clk_in, input wire din, output wire [3:0] q);
    ISERDESE2 #(.DATA_RATE("DDR"), .DATA_WIDTH(4), .INTERFACE_TYPE("NETWORKING"),
                .IOBDELAY("NONE"), .SERDES_MODE("MASTER"), .NUM_CE(2))
      u_is (.Q1(q[0]), .Q2(q[1]), .Q3(q[2]), .Q4(q[3]),
            .D(din), .CLK(clk_in), .CLKB(~clk_in), .CLKDIV(clk_in),
            .OCLK(1'b0), .OCLKB(1'b0), .RST(1'b0),
            .CE1(1'b1), .CE2(1'b1), .BITSLIP(1'b0),
            .DYNCLKDIVSEL(1'b0), .DYNCLKSEL(1'b0));
endmodule
