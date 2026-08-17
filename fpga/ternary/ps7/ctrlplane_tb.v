`timescale 1ns/1ps
// Can the processor reach the radio's control pins? This drives ps7_ad9361_ctrl
// through the same AXI path Linux uses, with a shift-register slave on the SPI
// pins -- not an AD9361 model, for the reason spi_master_tb.v gives.
//
// What it settles is the plumbing: a register write at 0x40010034 becomes a
// transaction on the pins, the reply comes back readable at the same address,
// and 0x40010038 drives resetb, enable and txnrx. That is the whole of what was
// severed when a bitstream with no outputs was loaded.
module spi_slave_sh #(parameter WIDTH=24) (
  input csn, input sclk, input mosi, output miso,
  input [WIDTH-1:0] to_send, output reg [WIDTH-1:0] received = 0);
  reg [WIDTH-1:0] sh = 0, out_sh = 0;
  assign miso = out_sh[WIDTH-1];
  always @(negedge csn) out_sh <= to_send;
  always @(posedge sclk) if (!csn) begin
    sh <= {sh[WIDTH-2:0], mosi};
    received <= {sh[WIDTH-2:0], mosi};
  end
  always @(negedge sclk) if (!csn) out_sh <= {out_sh[WIDTH-2:0], 1'b0};
endmodule

module tb;
  reg clk50 = 0; always #10 clk50 = ~clk50;
  reg bclk = 0;  always #10 bclk = ~bclk;

  wire csn, sclk, mosi, miso, resetb, enable, txnrx;
  reg [23:0] slave_word = 24'h000000;
  wire [23:0] slave_got;

  ps7_ad9361_ctrl dut (.spi_csn(csn), .spi_clk(sclk), .spi_mosi(mosi),
                       .spi_miso(miso), .gpio_resetb(resetb),
                       .enable(enable), .txnrx(txnrx));
  spi_slave_sh s (.csn(csn), .sclk(sclk), .mosi(mosi), .miso(miso),
                  .to_send(slave_word), .received(slave_got));

  initial begin
    dut.ps7_i.frstn = 4'b0000; dut.ps7_i.gpo = 64'd0;
    #200 dut.ps7_i.frstn = 4'b1111;
  end
  always @(clk50) dut.ps7_i.fclk[0] = clk50;
  always @(bclk)  dut.ps7_i.fclk[1] = bclk;

  task axi_write(input [31:0] a, input [31:0] d);
    integer g; begin
      @(posedge clk50);
      dut.ps7_i.awaddr <= a; dut.ps7_i.awlen <= 0; dut.ps7_i.awvalid <= 1;
      g=0; while (!dut.gp_awready && g<400) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.awvalid <= 0;
      dut.ps7_i.wdata <= d; dut.ps7_i.wlast <= 1; dut.ps7_i.wvalid <= 1;
      g=0; while (!dut.gp_wready && g<400) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.wvalid <= 0; dut.ps7_i.bready <= 1;
      g=0; while (!dut.gp_bvalid && g<2000) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.bready <= 0;
    end
  endtask
  reg [31:0] rdval;
  task axi_read(input [31:0] a);
    integer g; begin
      @(posedge clk50);
      dut.ps7_i.araddr <= a; dut.ps7_i.arlen <= 0; dut.ps7_i.arvalid <= 1;
      g=0; while (!dut.gp_arready && g<400) begin @(posedge clk50); g=g+1; end
      @(posedge clk50); dut.ps7_i.arvalid <= 0; dut.ps7_i.rready <= 1;
      g=0; while (!dut.gp_rvalid && g<2000) begin @(posedge clk50); g=g+1; end
      rdval = dut.gp_rdata;
      @(posedge clk50); dut.ps7_i.rready <= 0;
    end
  endtask

  integer errs = 0, n, g;
  reg [23:0] tx;

  initial begin
    #400;
    axi_read(32'h4001_0000);
    if (rdval !== 32'h5A5A47C0) begin
      $display("  FAIL bridge magic %h", rdval); errs=errs+1; end

    $display("1. control pins follow their register");
    axi_write(32'h4001_0038, 32'h0);
    #200;
    if ({txnrx,enable,resetb} !== 3'b000) begin
      $display("  FAIL pins %b with register 0", {txnrx,enable,resetb}); errs=errs+1; end
    axi_write(32'h4001_0038, 32'h7);
    #200;
    if ({txnrx,enable,resetb} !== 3'b111) begin
      $display("  FAIL pins %b with register 7", {txnrx,enable,resetb}); errs=errs+1; end
    axi_write(32'h4001_0038, 32'h1);   // resetb high, radio out of reset
    #200;
    if (resetb !== 1'b1 || enable !== 1'b0 || txnrx !== 1'b0) begin
      $display("  FAIL resetb-only failed"); errs=errs+1; end
    axi_read(32'h4001_0038);
    if (rdval[2:0] !== 3'b001) begin
      $display("  FAIL control read back %h", rdval); errs=errs+1; end

    $display("2. a register write becomes a transaction on the pins");
    for (n=0; n<4; n=n+1) begin
      tx = 24'h800037 + (n * 24'h001100);
      slave_word = 24'h0A0000 + n;
      axi_write(32'h4001_0034, {8'd0, tx});
      // poll until the master reports itself idle, bounded so a stuck engine
      // shows as a failure rather than a hung simulation
      g = 0;
      axi_read(32'h4001_0034);
      while (rdval[31] && g < 500) begin
        axi_read(32'h4001_0034);
        g = g + 1;
      end
      if (g >= 500) begin
        $display("  FAIL spi never went idle"); errs = errs + 1; end
      if (slave_got !== tx) begin
        $display("  FAIL sent %h, slave got %h", tx, slave_got); errs=errs+1; end
      if (rdval[23:0] !== slave_word) begin
        $display("  FAIL slave sent %h, read back %h", slave_word, rdval[23:0]);
        errs=errs+1; end
    end

    $display("");
    $display("errors: %0d", errs);
    if (errs == 0) $display("CONTROL PLANE OK");
    $finish;
  end
  initial begin #3000000; $display("TIMEOUT"); $finish; end
endmodule
