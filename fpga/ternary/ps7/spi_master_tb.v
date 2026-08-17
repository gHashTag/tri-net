`timescale 1ns/1ps
// The slave here is a shift register, not an AD9361 model, and that is
// deliberate: a master and a protocol model that agree only with each other
// prove nothing about the real part. What this settles is the shift mechanism --
// bit order, sampling edge, chip select framing, and that what goes out on MOSI
// is what the slave receives while what the slave sends comes back on MISO.
module spi_slave #(parameter WIDTH=24) (
  input csn, input sclk, input mosi, output miso,
  input [WIDTH-1:0] to_send, output reg [WIDTH-1:0] received = 0);
  reg [WIDTH-1:0] sh = 0;
  reg [WIDTH-1:0] out_sh = 0;
  reg loaded = 0;
  assign miso = out_sh[WIDTH-1];
  always @(negedge csn) begin out_sh <= to_send; loaded <= 1; end
  always @(posedge sclk) if (!csn) begin
    sh <= {sh[WIDTH-2:0], mosi};
    received <= {sh[WIDTH-2:0], mosi};
  end
  always @(negedge sclk) if (!csn) out_sh <= {out_sh[WIDTH-2:0], 1'b0};
endmodule

module tb;
  localparam W=24;
  reg clk=0; always #5 clk=~clk;
  reg rstn=0, start=0;
  reg  [W-1:0] wdata=0, to_send=0;
  wire [W-1:0] rdata, received;
  wire busy, done, csn, sclk, mosi, miso;

  spi_master #(.WIDTH(W), .DIV(4)) m (
    .clk(clk), .rstn(rstn), .start(start), .wdata(wdata), .rdata(rdata),
    .busy(busy), .done(done), .spi_csn(csn), .spi_clk(sclk),
    .spi_mosi(mosi), .spi_miso(miso));
  spi_slave #(.WIDTH(W)) s (
    .csn(csn), .sclk(sclk), .mosi(mosi), .miso(miso),
    .to_send(to_send), .received(received));

  integer errs=0, n;
  reg [W-1:0] tx, rx;

  task xfer(input [W-1:0] out_word, input [W-1:0] slave_word);
    integer g; begin
      to_send = slave_word;
      @(posedge clk); wdata <= out_word; start <= 1;
      @(posedge clk); start <= 0;
      g=0; while (!done && g<20000) begin @(posedge clk); g=g+1; end
      if (!done) begin $display("  HANG on %h", out_word); errs=errs+1; end
      @(posedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk); rstn <= 1; repeat (4) @(posedge clk);
    if (csn !== 1'b1) begin $display("  chip select not idle high"); errs=errs+1; end

    $display("1. what the master sends is what the slave receives");
    for (n=0; n<6; n=n+1) begin
      tx = 24'h5A0000 + (n*24'h010101);
      xfer(tx, 24'h000000);
      if (received !== tx) begin
        $display("  FAIL sent %h, slave got %h", tx, received); errs=errs+1; end
    end

    $display("2. what the slave sends comes back on MISO");
    for (n=0; n<6; n=n+1) begin
      rx = 24'h0A37C0 + (n*24'h001001);
      xfer(24'h000000, rx);
      if (rdata !== rx) begin
        $display("  FAIL slave sent %h, master read %h", rx, rdata); errs=errs+1; end
    end

    $display("3. both directions at once");
    xfer(24'hA5C39F, 24'h0A0B0C);
    if (received !== 24'hA5C39F || rdata !== 24'h0A0B0C) begin
      $display("  FAIL duplex: slave got %h, master read %h", received, rdata);
      errs=errs+1; end

    $display("4. chip select frames each transaction");
    if (csn !== 1'b1) begin $display("  FAIL csn low after done"); errs=errs+1; end

    $display("");
    $display("errors: %0d", errs);
    if (errs == 0) $display("SPI MASTER OK");
    $finish;
  end
  initial begin #2000000; $display("TIMEOUT"); $finish; end
endmodule
