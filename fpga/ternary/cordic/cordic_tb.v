`timescale 1ns/1ps
// Feed a sweep of angles, compare CORDIC cos/sin to $cos/$sin, report max error.
module cordic_tb;
  reg clk=0,rst=1,in_valid=0; reg signed [15:0] theta;
  wire out_valid; wire signed [15:0] cos_o, sin_o;
  cordic dut(.clk(clk),.rst(rst),.in_valid(in_valid),.theta(theta),
             .out_valid(out_valid),.cos_o(cos_o),.sin_o(sin_o));
  always #5 clk=~clk;
  real pi, ang, rc, rs, ec, es, maxe; integer i, deg;
  reg signed [15:0] tq [0:360]; real refc [0:360], refs [0:360];
  integer sent, got;
  initial begin
    pi=3.14159265358979; maxe=0.0;
    // precompute test angles (every 5 degrees) and references
    for(i=0;i<=72;i=i+1) begin
      deg=i*5-180; ang=deg*pi/180.0;
      tq[i]=$rtoi(ang/(2.0*pi)*65536.0);
      refc[i]=$cos(ang); refs[i]=$sin(ang);
    end
    @(negedge clk); rst=0;
    // stream angles in; collect outputs (17-cycle latency) via a shift of index
    fork
      begin // feed
        for(i=0;i<=72;i=i+1) begin @(negedge clk); in_valid=1; theta=tq[i]; end
        @(negedge clk); in_valid=0;
      end
      begin // collect
        got=0;
        while(got<=72) begin
          @(posedge clk); #1;
          if(out_valid) begin
            rc=cos_o/32768.0; rs=sin_o/32768.0;
            ec=(rc-refc[got]); if(ec<0)ec=-ec; es=(rs-refs[got]); if(es<0)es=-es;
            if(ec>maxe)maxe=ec; if(es>maxe)maxe=es;
            got=got+1;
          end
        end
      end
    join
    $display("CORDIC sin/cos over 73 angles: max error = %f (%.1f LSB of Q15)", maxe, maxe*32768.0);
    if(maxe < 0.005) $display("CORDIC: sin/cos correct (zero multipliers) -- RoPE transcendental OK");
    else             $display("CORDIC: error too large");
    $finish;
  end
endmodule
