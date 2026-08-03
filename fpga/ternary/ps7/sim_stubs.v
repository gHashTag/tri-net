`timescale 1ns/1ps
// PS7 stub for simulation. Only the ports ps7_ad9361_rate actually uses are
// modelled: two fabric clocks, the reset, the EMIO GPIO and the M_AXI_GP0
// master. The testbench drives the AXI side exactly as Linux does through
// devmem, so the bridge in axi3_to_lite.v is exercised in place rather than
// bypassed.
module PS7 (
  output [3:0]  FCLKCLK,
  output [3:0]  FCLKRESETN,
  output [63:0] EMIOGPIOO,
  input  [63:0] EMIOGPIOI,
  output [63:0] EMIOGPIOTN,
  input         MAXIGP0ACLK,
  output [11:0] MAXIGP0AWID,  output [31:0] MAXIGP0AWADDR,
  output [ 3:0] MAXIGP0AWLEN, output        MAXIGP0AWVALID,
  input         MAXIGP0AWREADY,
  output [31:0] MAXIGP0WDATA, output [ 3:0] MAXIGP0WSTRB,
  output        MAXIGP0WLAST, output        MAXIGP0WVALID,
  input         MAXIGP0WREADY,
  input  [11:0] MAXIGP0BID,   input  [ 1:0] MAXIGP0BRESP,
  input         MAXIGP0BVALID, output       MAXIGP0BREADY,
  output [11:0] MAXIGP0ARID,  output [31:0] MAXIGP0ARADDR,
  output [ 3:0] MAXIGP0ARLEN, output        MAXIGP0ARVALID,
  input         MAXIGP0ARREADY,
  input  [11:0] MAXIGP0RID,   input  [31:0] MAXIGP0RDATA,
  input  [ 1:0] MAXIGP0RRESP, input         MAXIGP0RLAST,
  input         MAXIGP0RVALID, output       MAXIGP0RREADY
);
  // driven from the testbench hierarchically
  reg [3:0]  fclk = 4'b0000;
  reg [3:0]  frstn = 4'b0000;
  reg [63:0] gpo = 64'd0;
  reg [11:0] awid=0, arid=0; reg [31:0] awaddr=0, araddr=0, wdata=0;
  reg [3:0]  awlen=0, arlen=0, wstrb=4'hF;
  reg awvalid=0, wvalid=0, wlast=0, bready=0, arvalid=0, rready=0;
  assign FCLKCLK = fclk;
  assign FCLKRESETN = frstn;
  assign EMIOGPIOO = gpo;
  assign EMIOGPIOTN = 64'hFFFF_FFFF_FFFF_FFFF;
  assign MAXIGP0AWID=awid;   assign MAXIGP0AWADDR=awaddr;
  assign MAXIGP0AWLEN=awlen; assign MAXIGP0AWVALID=awvalid;
  assign MAXIGP0WDATA=wdata; assign MAXIGP0WSTRB=wstrb;
  assign MAXIGP0WLAST=wlast; assign MAXIGP0WVALID=wvalid;
  assign MAXIGP0BREADY=bready;
  assign MAXIGP0ARID=arid;   assign MAXIGP0ARADDR=araddr;
  assign MAXIGP0ARLEN=arlen; assign MAXIGP0ARVALID=arvalid;
  assign MAXIGP0RREADY=rready;
endmodule

module BUFG (output O, input I);
  assign O = I;
endmodule

// Stubs for primitives that appear in files iverilog elaborates but that this
// configuration never instantiates. Empty bodies are correct here precisely
// because nothing reaches them; if one ever did, the simulation would show it
// as an undriven output rather than silently working.
module MULT_MACRO #(parameter DEVICE="7SERIES", parameter LATENCY=3,
                    parameter WIDTH_A=18, parameter WIDTH_B=18)
  (output [WIDTH_A+WIDTH_B-1:0] P, input [WIDTH_A-1:0] A,
   input [WIDTH_B-1:0] B, input CE, input CLK, input RST);
endmodule
module IBUFDS (output O, input I, input IB); endmodule
module OBUFDS (output O, output OB, input I); endmodule
module IDDR #(parameter DDR_CLK_EDGE="SAME_EDGE")
  (output Q1, output Q2, input C, input CE, input D, input R, input S);
endmodule
module ODDR #(parameter DDR_CLK_EDGE="SAME_EDGE", parameter INIT=0,
              parameter SRTYPE="SYNC")
  (output Q, input C, input CE, input D1, input D2, input R, input S);
endmodule
module BUFR #(parameter BUFR_DIVIDE="BYPASS", parameter SIM_DEVICE="7SERIES")
  (output O, input CE, input CLR, input I); assign O = I; endmodule
module BUFIO (output O, input I); assign O = I; endmodule
module IDELAYCTRL #(parameter SIM_DEVICE="7SERIES")
  (output RDY, input REFCLK, input RST); assign RDY = 1'b1; endmodule
module IDELAYE2 #(parameter CINVCTRL_SEL="FALSE", parameter DELAY_SRC="IDATAIN",
                  parameter HIGH_PERFORMANCE_MODE="FALSE",
                  parameter IDELAY_TYPE="VAR_LOAD", parameter IDELAY_VALUE=0,
                  parameter PIPE_SEL="FALSE", parameter REFCLK_FREQUENCY=200.0,
                  parameter SIGNAL_PATTERN="DATA")
  (output [4:0] CNTVALUEOUT, output DATAOUT, input C, input CE,
   input CINVCTRL, input [4:0] CNTVALUEIN, input DATAIN, input IDATAIN,
   input INC, input LD, input LDPIPEEN, input REGRST);
  assign DATAOUT = IDATAIN;
endmodule
module ISERDESE2 #(parameter DATA_RATE="DDR", parameter DATA_WIDTH=4,
                   parameter INTERFACE_TYPE="NETWORKING",
                   parameter IOBDELAY="NONE", parameter NUM_CE=2,
                   parameter SERDES_MODE="MASTER")
  (output O, output Q1,output Q2,output Q3,output Q4,output Q5,output Q6,
   output Q7,output Q8, output SHIFTOUT1, output SHIFTOUT2,
   input BITSLIP, input CE1, input CE2, input CLK, input CLKB, input CLKDIV,
   input CLKDIVP, input D, input DDLY, input DYNCLKDIVSEL, input DYNCLKSEL,
   input OCLK, input OCLKB, input OFB, input RST, input SHIFTIN1,
   input SHIFTIN2);
endmodule
module OSERDESE2 #(parameter DATA_RATE_OQ="DDR", parameter DATA_RATE_TQ="SDR",
                   parameter DATA_WIDTH=4, parameter SERDES_MODE="MASTER",
                   parameter TRISTATE_WIDTH=1)
  (output OFB, output OQ, output SHIFTOUT1, output SHIFTOUT2, output TBYTEOUT,
   output TFB, output TQ, input CLK, input CLKDIV, input D1,input D2,input D3,
   input D4,input D5,input D6,input D7,input D8, input OCE, input RST,
   input SHIFTIN1, input SHIFTIN2, input T1,input T2,input T3,input T4,
   input TBYTEIN, input TCE);
endmodule
module MMCME2_ADV #(parameter BANDWIDTH="OPTIMIZED") ();
endmodule
module OBUFTDS (output O, output OB, input I, input T); endmodule
module OBUFT (output O, input I, input T); endmodule
module IOBUF (output O, inout IO, input I, input T); endmodule
module IBUF (output O, input I); assign O = I; endmodule
module OBUF (output O, input I); assign O = I; endmodule
module BUFGCE (output O, input CE, input I); assign O = I & CE; endmodule
module STARTUPE2 #(parameter PROG_USR="FALSE") (); endmodule

// DSP48E1 appears in ad_dcfilter, which IS elaborated here -- but its product
// reaches the datapath only through `data_dcfilt`, and that is selected only
// when `dcfilt_enb` is 1. This configuration leaves the DC filter disabled, so
// the multiplier's result is discarded and a zeroed stub changes nothing on the
// active path. If the filter were ever enabled, this stub would make the
// simulation wrong -- which is why it says so here rather than passing quietly.
module DSP48E1 #(parameter A_INPUT="DIRECT", parameter B_INPUT="DIRECT",
  parameter USE_DPORT="FALSE", parameter USE_MULT="MULTIPLY",
  parameter AREG=1, parameter BREG=1, parameter CREG=1, parameter DREG=1,
  parameter MREG=1, parameter PREG=1, parameter ADREG=1,
  parameter ACASCREG=1, parameter BCASCREG=1, parameter ALUMODEREG=1,
  parameter CARRYINREG=1, parameter CARRYINSELREG=1, parameter INMODEREG=1,
  parameter OPMODEREG=1, parameter USE_SIMD="ONE48",
  parameter MASK=48'h3FFFFFFFFFFF, parameter PATTERN=48'h000000000000,
  parameter SEL_MASK="MASK", parameter SEL_PATTERN="PATTERN",
  parameter USE_PATTERN_DETECT="NO_PATDET", parameter AUTORESET_PATDET="NO_RESET")
 (output [29:0] ACOUT, output [17:0] BCOUT, output CARRYCASCOUT,
  output CARRYOUT_dummy, output [3:0] CARRYOUT, output MULTSIGNOUT,
  output OVERFLOW, output [47:0] P, output PATTERNBDETECT,
  output PATTERNDETECT, output [47:0] PCOUT, output UNDERFLOW,
  input [29:0] A, input [29:0] ACIN, input [3:0] ALUMODE, input [17:0] B,
  input [17:0] BCIN, input [47:0] C, input CARRYCASCIN, input CARRYIN,
  input [2:0] CARRYINSEL, input CEA1, input CEA2, input CEAD, input CEALUMODE,
  input CEB1, input CEB2, input CEC, input CECARRYIN, input CECTRL, input CED,
  input CEINMODE, input CEM, input CEP, input CLK, input [24:0] D,
  input [4:0] INMODE, input MULTSIGNIN, input [6:0] OPMODE, input [47:0] PCIN,
  input RSTA, input RSTALLCARRYIN, input RSTALUMODE, input RSTB, input RSTC,
  input RSTCTRL, input RSTD, input RSTINMODE, input RSTM, input RSTP);
  assign P = 48'd0; assign PCOUT = 48'd0; assign ACOUT = 30'd0;
  assign BCOUT = 18'd0; assign CARRYOUT = 4'd0;
endmodule
