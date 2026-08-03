`timescale 1ps/1ps
// ad_mul_open -- a drop-in replacement for ADI's ad_mul that does not need
// Xilinx's UNIMACRO library.
//
// Why this exists. Putting our own core inside the AD9361 datapath means
// building ADI's HDL through yosys, and yosys ships **no UNIMACRO library at
// all** -- verified: the yosys share directory in the openXC7 container
// contains no file mentioning MULT_MACRO. ADI's `ad_mul` is the only file in
// the whole tree that instantiates it, and it is reached from `ad_iqcor` and
// the `ad_dds_*` modules, which are unavoidable generic dependencies. So this
// one wrapper is the difference between "the tree elaborates" and "it does not".
//
// What makes the replacement safe rather than hopeful: ADI's instantiation
// pins the two parameters that carry all the subtle behaviour.
//
//     MULT_MACRO #(.LATENCY(3), .WIDTH_A(A), .WIDTH_B(B)) i_mult_macro (
//       .CE(1'b1), .RST(1'b0), .CLK(clk), .A(data_a), .B(data_b), .P(data_p));
//
// CE is tied high and RST is tied low. Every documented trap in reimplementing
// MULT_MACRO -- what RST clears and whether it is synchronous, how CE gates the
// individual pipeline stages, the combinational special case at LATENCY 0 --
// is unreachable at this call site. What remains is a signed multiply with
// three pipeline registers, which is unambiguous.
//
// Signedness is the one thing that would silently corrupt the datapath if it
// were got wrong. `ad_mul` declares its ports as plain vectors, but MULT_MACRO
// treats A and B as **signed** (UG953) and produces a signed product of
// WIDTH_A + WIDTH_B bits. This module therefore casts explicitly rather than
// relying on the surrounding declarations.
//
// Latency is corroborated independently by ADI's own code: `ad_mul` carries a
// three-deep delay line (p1_ddata -> p2_ddata -> ddata_out) to match the
// multiplier, which is only correct if the multiplier is three deep too.

module ad_mul_open #(
  parameter A_DATA_WIDTH     = 17,
  parameter B_DATA_WIDTH     = 17,
  parameter DELAY_DATA_WIDTH = 16
) (
  input                                     clk,
  input   [               A_DATA_WIDTH-1:0] data_a,
  input   [               B_DATA_WIDTH-1:0] data_b,
  output  [A_DATA_WIDTH + B_DATA_WIDTH-1:0] data_p,

  input       [(DELAY_DATA_WIDTH-1):0]      ddata_in,
  output  reg [(DELAY_DATA_WIDTH-1):0]      ddata_out = 'd0
);

  localparam P_WIDTH = A_DATA_WIDTH + B_DATA_WIDTH;

  // side-channel delay, unchanged from ADI's original: three stages, matching
  // the multiplier so that ddata_out lines up with data_p
  reg [(DELAY_DATA_WIDTH-1):0] p1_ddata = 'd0;
  reg [(DELAY_DATA_WIDTH-1):0] p2_ddata = 'd0;

  always @(posedge clk) begin
    p1_ddata  <= ddata_in;
    p2_ddata  <= p1_ddata;
    ddata_out <= p2_ddata;
  end

  // LATENCY(3) in MULT_MACRO is an A/B input register, an internal M register
  // and an output P register. Reproduced literally, in that order, so the
  // pipeline depth and the value at every stage match rather than merely the
  // final result.
  reg signed [A_DATA_WIDTH-1:0] a_reg = 'd0;   // stage 1: input registers
  reg signed [B_DATA_WIDTH-1:0] b_reg = 'd0;
  reg signed [P_WIDTH-1:0]      m_reg = 'd0;   // stage 2: the M register
  reg signed [P_WIDTH-1:0]      p_reg = 'd0;   // stage 3: the P register

  always @(posedge clk) begin
    a_reg <= $signed(data_a);
    b_reg <= $signed(data_b);
    m_reg <= a_reg * b_reg;
    p_reg <= m_reg;
  end

  assign data_p = p_reg;

endmodule
