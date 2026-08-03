module prim_oserdes (input wire clk_in, output wire dout);
    wire clkdiv = clk_in;
    OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(4),
                .SERDES_MODE("MASTER"), .TRISTATE_WIDTH(1))
      u_os (.OQ(dout), .CLK(clk_in), .CLKDIV(clkdiv), .RST(1'b0),
            .D1(1'b0), .D2(1'b1), .D3(1'b0), .D4(1'b1),
            .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
            .OCE(1'b1), .TCE(1'b0), .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
            .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .TBYTEIN(1'b0));
endmodule
