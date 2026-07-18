`timescale 1ns/1ps
`default_nettype none
// Drive clkrec with the REAL .11<->.12 sample-clock offset measured from a live
// DSSS capture (-0.85 ppm, -26 Hz at 30.72 MSPS). Source = clk/4 so 1 ppm is ~67
// LSBs (resolvable). Confirms the RTL loop recovers the real radio clock offset.
module clkrec_live_tb;
    localparam PW=28, FW=10;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    localparam [PW-1:0] INC_BASE = 28'd67108864;      // clk/4 nominal
    localparam integer  REAL_PPM = -1;                // real measured ~-0.85 ppm (.11->.12)
    reg [PW-1:0] src_phase=0; reg arrive=0; reg [31:0] lfsr=32'hBEEF;
    // source increment = base * (1 + real_ppm) + small real-ish jitter
    wire signed [PW:0] src_inc = INC_BASE + ((INC_BASE/1000000)*REAL_PPM)
                               + (($signed({1'b0,lfsr[5:0]})-32));
    always @(posedge clk) begin
        lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        {arrive,src_phase}<={1'b0,src_phase}+src_inc[PW:0];
    end
    wire drain; wire [FW-1:0] fill; wire signed [PW:0] inc_now;
    clkrec #(.PW(PW),.FW(FW)) dut(.clk(clk),.rst(rst),.arrive(arrive),
        .inc_base(INC_BASE),.drain(drain),.fill(fill),.inc_now(inc_now));
    integer na=0,nd=0;
    always @(posedge clk) if(!rst) begin if(arrive)na<=na+1; if(drain)nd<=nd+1; end
    initial begin
        #100 rst=0; #2_000_000; na=0; nd=0; #6_000_000;
        $display("REAL .11<->.12 offset %0d ppm: fill=%0d/512  arrivals=%0d drains=%0d  ratio=%f",
                 REAL_PPM, fill, na, nd, (nd*1.0)/na);
        $display("  recovered clock tracks the real radio source rate within %f %%", (nd*1.0/na-1.0)*100.0);
        $finish;
    end
endmodule
`default_nettype wire
