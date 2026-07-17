`default_nettype none
// int8_dot -- K-wide signed int8 x int8 dot product (the attention Q.K^T / A.V
// primitive that CANNOT be ternary). Real multiplies -> DSP48E1. Registered
// inputs/output so nextpnr sees a real datapath. Measures the DSP a transformer
// pays for its data-dependent products, against tern_dot27's zero.
module int8_dot #(parameter integer K=32, parameter integer ACC=24)
  (input wire clk, input wire signed [K*8-1:0] a, input wire signed [K*8-1:0] b,
   output reg signed [ACC-1:0] dot);
  integer i; reg signed [ACC-1:0] s; reg signed [7:0] ai, bi;
  always @(posedge clk) begin
    s = 0;
    for (i=0;i<K;i=i+1) begin ai=a[i*8+:8]; bi=b[i*8+:8]; s = s + ai*bi; end
    dot <= s;
  end
endmodule
`default_nettype wire
