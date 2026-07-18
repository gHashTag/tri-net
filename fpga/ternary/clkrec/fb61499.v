`default_nettype none
// IEC 61499 function block on the ternary primitive (ASU_TP_SOM skeleton).
// Balyberdin's rule: "each interrupt checks all needed operands present; if so,
// executes the function block." Firing gate = ALL operands valid (his {no-data}
// is the absence of valid). Body = ternary sign-select MAC (our 0-DSP primitive):
// y = sum_i sel(w_i, x_i), sel = +x / -x / 0. Event in = `req` (from the recovered
// clock / SSI channel); event out = `cnf` one cycle after a valid firing.
module fb61499 #(
    parameter integer NO = 4,      // number of operands
    parameter integer W  = 8       // operand data width (signed)
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 req,          // trigger event (e.g. clkrec drain / SSI header)
    input  wire [NO-1:0]        valid,        // per-operand data-present flag (his no-data = !valid)
    input  wire [NO*W-1:0]      xin,          // packed signed operands
    input  wire [NO*2-1:0]      wgt,          // packed ternary weights: 01=+1, 10=-1, else 0
    output reg                  cnf,          // confirmation event: fired this cycle
    output reg  signed [W+3:0]  y             // MAC result (grows by log2(NO) bits)
);
    wire all_present = &valid;                // firing gate: every operand has data
    integer i;
    reg signed [W+3:0] acc;
    always @(*) begin
        acc = {(W+4){1'b0}};
        for (i=0;i<NO;i=i+1) begin
            case (wgt[i*2 +: 2])
                2'b01: acc = acc + $signed(xin[i*W +: W]);   // +x
                2'b10: acc = acc - $signed(xin[i*W +: W]);   // -x
                default: acc = acc;                          // 0 / no contribution
            endcase
        end
    end
    always @(posedge clk) begin
        if (rst) begin cnf<=1'b0; y<=0; end
        else if (req && all_present) begin       // fire ONLY when triggered AND all operands present
            y   <= acc;
            cnf <= 1'b1;
        end else begin
            cnf <= 1'b0;                          // no-data or no-event -> block does not execute
        end
    end
endmodule
`default_nettype wire
