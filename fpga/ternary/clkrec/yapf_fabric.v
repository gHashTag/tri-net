`default_nettype none
// Loadable-topology ЯПФ fabric: N ternary function blocks whose interconnect is
// PROGRAMMED at runtime, not baked into the bitstream (Balyberdin: "load the map of
// interconnections", "edit the connection structure during operation"). Each block's
// two operands are selected by config from a shared source set {external inputs,
// block outputs}; each block computes a ternary sign-select MAC. The dataflow wave
// propagates through whatever graph the config describes. Change config -> change
// the computation, no re-synthesis.
module yapf_fabric #(parameter integer NB=4, parameter integer W=8)(
    input  wire                 clk, rst,
    input  wire [4*W-1:0]       ext,          // 4 external operands (always valid)
    input  wire [NB*10-1:0]     cfg,          // per block: {w[3:0], sel1[2:0], sel0[2:0]}
    output wire signed [W-1:0]  yout          // final block output (topology's result)
);
    localparam integer NS = 4 + NB;           // sources: 4 external + NB block outputs
    reg  signed [W-1:0] y [0:NB-1];
    wire signed [W-1:0] src [0:NS-1];
    genvar s, b;
    generate
        for (s=0;s<4;s=s+1)  assign src[s]   = $signed(ext[s*W +: W]);
        for (s=0;s<NB;s=s+1) assign src[4+s] = y[s];
    endgenerate
    function signed [W-1:0] selmac;
        input [1:0] w; input signed [W-1:0] x;
        selmac = (w==2'b01) ? x : (w==2'b10) ? -x : {W{1'b0}};
    endfunction
    integer i;
    always @(posedge clk) begin
        if (rst) for (i=0;i<NB;i=i+1) y[i] <= {W{1'b0}};
        else for (i=0;i<NB;i=i+1) begin
            y[i] <= selmac(cfg[i*10+8 +: 2], src[ cfg[i*10+0 +: 3] ])   // w0 . src[sel0]
                  + selmac(cfg[i*10+6 +: 2], src[ cfg[i*10+3 +: 3] ]);  // w1 . src[sel1]
        end
    end
    assign yout = y[NB-1];                     // last block = the graph's output
endmodule
`default_nettype wire
