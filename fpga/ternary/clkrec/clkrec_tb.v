`timescale 1ns/1ps
`default_nettype none
// Testbench: inject arrivals at a SOURCE rate offset from the sink's free-run, with
// jitter, and confirm the NCO locks -- fill returns to setpoint and the drain rate
// equals the source rate (offset nulled). Source arrival rate is driven by a second
// (reference) phase accumulator so the ratio is exact.
module clkrec_tb;
    localparam PW=28, FW=10;
    reg clk=0, rst=1; always #5 clk=~clk;   // 100 MHz
    // sink free-run increment; source offset by +SRC_PPM via a bigger reference inc
    localparam [PW-1:0] INC_BASE = 28'd268435;         // ~ f_nom/f_clk * 2^28
    // source arrival generator: its own accumulator with an offset increment
    reg [PW-1:0] src_phase=0; reg arrive=0;
    localparam integer SRC_PPM = 200;                  // source is +200 ppm off the sink
    reg [31:0] lfsr=32'hACE1;                          // jitter source
    // combinational (defined from cycle 1): base * (1+ppm) with a small per-cycle dither
    wire [PW-1:0] src_inc = INC_BASE + ((INC_BASE/1000000)*SRC_PPM)
                          + (($signed({1'b0,lfsr[6:0]}) - 64) >>> 2);
    always @(posedge clk) begin
        lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        {arrive, src_phase} <= {1'b0, src_phase} + {1'b0, src_inc};  // carry-out = arrival strobe
    end
    wire drain; wire [FW-1:0] fill; wire signed [PW:0] inc_now;
    clkrec #(.PW(PW),.FW(FW)) dut(.clk(clk),.rst(rst),.arrive(arrive),
        .inc_base(INC_BASE),.drain(drain),.fill(fill),.inc_now(inc_now));
    // measure drain vs arrive counts over a window in steady state
    integer na=0, nd=0, i;
    reg meas=0;
    always @(posedge clk) if(!rst) begin
        if(arrive) na<=na+1;
        if(drain)  nd<=nd+1;
    end
    initial begin
        #100 rst=0;
        // let it lock
        #4_000_000;
        // steady-state window
        na=0; nd=0; #8_000_000;
        $display("SRC_PPM=%0d  fill=%0d (setpoint 512)  arrivals=%0d drains=%0d  ratio=%f",
                 SRC_PPM, fill, na, nd, (nd*1.0)/na);
        $display("  drain rate tracks source rate within %f %%",
                 (nd*1.0/na - 1.0)*100.0);
        $finish;
    end
endmodule
`default_nettype wire
