`default_nettype none
// Tiered-parallel form (ЯПФ) in RTL: a 2-tier dataflow of IEC 61499 ternary function
// blocks (the "wave of detonation"). Tier-1 blocks a,b fire when THEIR operands
// arrive; their results + confirm events become the operands + firing gate of tier-2
// block c. c cannot fire until BOTH tier-1 nodes produced data -- dataflow ordering by
// the {no-data} gate, no program counter. yc = wc.[ya,yb], ya = wa.xa, yb = wb.xb.
module yapf_cascade (
    input  wire                 clk, rst,
    input  wire                 req_a, req_b,   // tier-1 trigger events
    input  wire [1:0]           va, vb,         // tier-1 operand valid flags
    input  wire [15:0]          xa, xb,         // tier-1: two 8-bit signed operands each
    input  wire [3:0]           wa, wb, wc,     // ternary weights (2 per block)
    output reg                  cnf_c,          // final confirm event
    output reg  signed [15:0]   yc              // final result
);
    wire ca, cb; wire signed [11:0] ya, yb;
    fb61499 #(.NO(2),.W(8)) a (.clk(clk),.rst(rst),.req(req_a),.valid(va),.xin(xa),.wgt(wa),.cnf(ca),.y(ya));
    fb61499 #(.NO(2),.W(8)) b (.clk(clk),.rst(rst),.req(req_b),.valid(vb),.xin(xb),.wgt(wb),.cnf(cb),.y(yb));

    // DAG edges: latch tier-1 results + presence until tier-2 consumes them
    reg signed [11:0] ra, rb; reg pa, pb;
    wire req_c = pa & pb;                        // tier-2 fires only when BOTH tier-1 present
    wire cc; wire signed [15:0] yc_w;
    // tier-2: operands are the two sign-extended tier-1 results
    wire [23:0] xc = { rb, ra };   // two 12-bit tier-1 results as tier-2 operands
    fb61499 #(.NO(2),.W(12)) c (.clk(clk),.rst(rst),.req(req_c),.valid({pb,pa}),
        .xin(xc),.wgt(wc),.cnf(cc),.y(yc_w));

    always @(posedge clk) begin
        if (rst) begin pa<=0; pb<=0; ra<=0; rb<=0; cnf_c<=0; yc<=0; end
        else begin
            if (ca) begin ra<=ya; pa<=1'b1; end
            if (cb) begin rb<=yb; pb<=1'b1; end
            cnf_c <= cc;
            if (cc) begin yc<=yc_w; pa<=1'b0; pb<=1'b0; end  // consumed -> clear DAG edges
        end
    end
endmodule
`default_nettype wire
