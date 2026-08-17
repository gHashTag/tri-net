// IDELAYE2 + IDELAYCTRL: the input delay chain ADI uses to tune the AD9361 bus
module prim_idelay (input wire clk_in, input wire din, output wire dout);
    wire dly;
    IDELAYCTRL u_ctrl (.REFCLK(clk_in), .RST(1'b0), .RDY());
    IDELAYE2 #(.IDELAY_TYPE("FIXED"), .IDELAY_VALUE(16), .DELAY_SRC("IDATAIN"),
               .HIGH_PERFORMANCE_MODE("TRUE"), .REFCLK_FREQUENCY(200.0),
               .SIGNAL_PATTERN("DATA"))
      u_dly (.IDATAIN(din), .DATAOUT(dly), .C(clk_in), .CE(1'b0), .INC(1'b0),
             .LD(1'b0), .LDPIPEEN(1'b0), .REGRST(1'b0), .CINVCTRL(1'b0),
             .CNTVALUEIN(5'd0), .CNTVALUEOUT(), .DATAIN(1'b0));
    reg q; always @(posedge clk_in) q <= dly;
    assign dout = q;
endmodule
