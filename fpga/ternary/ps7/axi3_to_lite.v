`timescale 1ns/1ps
// axi3_to_lite -- connect Zynq's M_AXI_GP0 (AXI3, bursting) to an AXI4-Lite
// slave, so that ADI's axi_ad9361 control registers can be reached from Linux
// with devmem.
//
// Why this exists. The correlator-in-datapath image read back adc_enable_i0 = 0
// on silicon: the vendor core's receive channel was never switched on, because
// nothing ever wrote its registers. In a real system Linux does that over AXI.
// There is no vendor-free AXI interconnect in this flow, so here is a minimal
// one that handles exactly what a CPU register access needs.
//
// Two deliberate choices, both about not hanging the CPU:
//
//   * Bursts are iterated rather than rejected. A rejected burst would leave
//     the PS waiting for beats that never come, and the only recovery is a
//     power cycle.
//   * Every transaction has a timeout. If the Lite slave never asserts ready,
//     the bridge completes the transaction itself with SLVERR after TIMEOUT
//     cycles. A bus error is recoverable and diagnostic; a hang is neither.
module axi3_to_lite #(
  parameter TIMEOUT = 1024
) (
  input             clk,
  input             rstn,
  // AXI3 slave side, from PS7 M_AXI_GP0
  input      [11:0] s_awid,
  input      [31:0] s_awaddr,
  input      [ 3:0] s_awlen,
  input             s_awvalid,
  output reg        s_awready,
  input      [31:0] s_wdata,
  input      [ 3:0] s_wstrb,
  input             s_wlast,
  input             s_wvalid,
  output reg        s_wready,
  output reg [11:0] s_bid,
  output reg [ 1:0] s_bresp,
  output reg        s_bvalid,
  input             s_bready,
  input      [11:0] s_arid,
  input      [31:0] s_araddr,
  input      [ 3:0] s_arlen,
  input             s_arvalid,
  output reg        s_arready,
  output reg [11:0] s_rid,
  output reg [31:0] s_rdata,
  output reg [ 1:0] s_rresp,
  output reg        s_rlast,
  output reg        s_rvalid,
  input             s_rready,
  // AXI4-Lite master side, to the slave
  output reg [31:0] m_awaddr,
  output reg        m_awvalid,
  input             m_awready,
  output reg [31:0] m_wdata,
  output reg [ 3:0] m_wstrb,
  output reg        m_wvalid,
  input             m_wready,
  input             m_bvalid,
  input      [ 1:0] m_bresp,
  output reg        m_bready,
  output reg [31:0] m_araddr,
  output reg        m_arvalid,
  input             m_arready,
  input      [31:0] m_rdata,
  input      [ 1:0] m_rresp,
  input             m_rvalid,
  output reg        m_rready
);

  localparam W_IDLE=0, W_DATA=1, W_ADDR=2, W_RESP=3, W_DONE=4, W_BRESP=5;
  localparam R_IDLE=0, R_ADDR=1, R_DATA=2, R_SEND=3;

  reg [2:0]  wst = W_IDLE;
  reg [31:0] waddr;
  reg [3:0]  wbeats;
  reg [11:0] wid;
  reg [1:0]  wresp;
  reg [15:0] wtmo;

  always @(posedge clk) begin
    if (!rstn) begin
      wst <= W_IDLE; s_awready <= 0; s_wready <= 0; s_bvalid <= 0;
      m_awvalid <= 0; m_wvalid <= 0; m_bready <= 0; wresp <= 2'b00;
    end else begin
      s_awready <= 0; s_wready <= 0;
      case (wst)
        W_IDLE: if (s_awvalid) begin
          waddr <= s_awaddr; wbeats <= s_awlen; wid <= s_awid;
          wresp <= 2'b00; s_awready <= 1; wst <= W_DATA;
        end
        W_DATA: if (s_wvalid) begin
          m_awaddr <= waddr; m_awvalid <= 1;
          m_wdata  <= s_wdata; m_wstrb <= s_wstrb; m_wvalid <= 1;
          s_wready <= 1; wtmo <= 0; wst <= W_ADDR;
        end
        W_ADDR: begin
          if (m_awready) m_awvalid <= 0;
          if (m_wready)  m_wvalid  <= 0;
          wtmo <= wtmo + 1;
          if (!m_awvalid && !m_wvalid) begin
            m_bready <= 1; wst <= W_RESP;
          end else if (wtmo == TIMEOUT) begin
            // slave never accepted: abandon and report a bus error
            m_awvalid <= 0; m_wvalid <= 0; wresp <= 2'b10; wst <= W_DONE;
          end
        end
        W_RESP: begin
          wtmo <= wtmo + 1;
          if (m_bvalid) begin
            m_bready <= 0;
            if (m_bresp != 2'b00) wresp <= m_bresp;
            wst <= W_DONE;
          end else if (wtmo == TIMEOUT) begin
            m_bready <= 0; wresp <= 2'b10; wst <= W_DONE;
          end
        end
        W_DONE: begin
          if (wbeats != 0) begin
            // next beat of the burst: same handshake, incremented address
            wbeats <= wbeats - 1; waddr <= waddr + 4; wst <= W_DATA;
          end else begin
            s_bid <= wid; s_bresp <= wresp; s_bvalid <= 1; wst <= W_BRESP;
          end
        end
        W_BRESP: if (s_bready) begin s_bvalid <= 0; wst <= W_IDLE; end
        default: wst <= W_IDLE;
      endcase
    end
  end

  reg [1:0]  rst_st = R_IDLE;
  reg [31:0] raddr;
  reg [3:0]  rbeats;
  reg [11:0] rid;
  reg [15:0] rtmo;

  always @(posedge clk) begin
    if (!rstn) begin
      rst_st <= R_IDLE; s_arready <= 0; s_rvalid <= 0;
      m_arvalid <= 0; m_rready <= 0;
    end else begin
      s_arready <= 0;
      case (rst_st)
        R_IDLE: if (s_arvalid) begin
          raddr <= s_araddr; rbeats <= s_arlen; rid <= s_arid;
          s_arready <= 1; rst_st <= R_ADDR;
        end
        R_ADDR: begin
          m_araddr <= raddr; m_arvalid <= 1; m_rready <= 1;
          rtmo <= 0; rst_st <= R_DATA;
        end
        R_DATA: begin
          if (m_arready) m_arvalid <= 0;
          rtmo <= rtmo + 1;
          if (m_rvalid) begin
            m_arvalid <= 0; m_rready <= 0;
            s_rdata <= m_rdata; s_rresp <= m_rresp;
            s_rid <= rid; s_rlast <= (rbeats == 0); s_rvalid <= 1;
            rst_st <= R_SEND;
          end else if (rtmo == TIMEOUT) begin
            m_arvalid <= 0; m_rready <= 0;
            s_rdata <= 32'hBADA_C7E5; s_rresp <= 2'b10;
            s_rid <= rid; s_rlast <= (rbeats == 0); s_rvalid <= 1;
            rst_st <= R_SEND;
          end
        end
        R_SEND: if (s_rready) begin
          s_rvalid <= 0;
          if (rbeats != 0) begin
            rbeats <= rbeats - 1; raddr <= raddr + 4; rst_st <= R_ADDR;
          end else rst_st <= R_IDLE;
        end
      endcase
    end
  end

endmodule
