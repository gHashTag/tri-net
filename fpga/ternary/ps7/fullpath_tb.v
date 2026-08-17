`timescale 1ns/1ps
// Full-path simulation: the design under test is ps7_ad9361_rate exactly as
// built, with a PS7 stub in place of the processor. The testbench performs the
// same AXI writes Linux performs through devmem -- release the core reset,
// enable channel 0 with sign extension, select the matched PN stimulus, arm the
// capture -- then reads the capture memories back over the same bridge.
//
// This exists because the board is a finite resource and was, at the time of
// writing, unreachable. Anything answerable here should not cost a board run.
module tb;
  localparam N=63, ACC=24;
  reg clk50 = 0;  always #10 clk50 = ~clk50;      // 50 MHz
  reg bclk  = 0;
  integer bper = 10;                               // ns half-period, swept
  always #(bper) bclk = ~bclk;

  wire [31:0] dummy;
  ps7_ad9361_rate dut ();

  // drive the stub
  initial begin
    dut.ps7_i.frstn = 4'b0000;
    dut.ps7_i.gpo   = 64'd0;
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

  integer tp [0:N-1];
  integer i, j, k, errs, errs2, expect_, lag, sweep, pv, best, bestlag, ph;
  reg [31:0] stat;
  reg [15:0] ins  [0:127];
  reg [31:0] outs [0:127];

  initial begin
    for (i=0;i<N;i=i+1) tp[i] = ((i&1)^((i>>2)&1)^((i>>4)&1)) ? 1 : -1;
    #400;
    axi_read(32'h4001_0000);
    $display("bridge magic  : %h  (expect 5A5A47C0)", rdval);
    axi_read(32'h4000_0000);
    $display("ADI version   : %h  (expect 000A0300)", rdval);

    // Phase sweep at 31.25 MHz, the one rate hardware failed and simulation
    // did not. If some start phase reproduces the failure, the cause is the
    // capture-start alignment; if none does, the residual is on the silicon
    // side and not in this logic.
    bper = 8;
    axi_write(32'h4000_0040, 32'h3);
    axi_write(32'h4000_0400, 32'h51);
    axi_write(32'h4001_0028, 32'hA);
    $display("");
    $display("start-phase sweep at lclk 31.25 MHz");
    for (ph = 0; ph < 8; ph = ph + 1) begin
      axi_write(32'h4001_0020, 32'h0);
      #2000;
      for (i = 0; i < ph; i = i + 1) @(posedge clk50);
      axi_write(32'h4001_0020, 32'h1);
      #700000;
      axi_read(32'h4001_0024);
      stat = rdval;                 // latch it: rdval is clobbered by the reads
      for (k=0;k<128;k=k+1) begin
        axi_read(32'h4001_0400 + k*4); ins[k]  = rdval[15:0];
        axi_read(32'h4001_0800 + k*4); outs[k] = rdval;
      end
      pv = 0;
      for (k=0;k<128;k=k+1) if (outs[k][24]) pv = pv + 1;
      errs = 0;
      for (k=N+2;k<128;k=k+1) begin
        lag = outs[k][24] ? 2 : 1;
        expect_ = 0;
        for (i=0;i<N;i=i+1) expect_ = expect_ + tp[i]*$signed(ins[k-lag-i]);
        if ($signed(outs[k][23:0]) !== $signed(expect_[ACC-1:0])) errs = errs + 1;
      end
      best = 9999;
      for (j=1;j<4;j=j+1) begin
        errs2 = 0;
        for (k=N+j;k<128;k=k+1) begin
          expect_ = 0;
          for (i=0;i<N;i=i+1) expect_ = expect_ + tp[i]*$signed(ins[k-j-i]);
          if ($signed(outs[k][23:0]) !== $signed(expect_[ACC-1:0])) errs2 = errs2 + 1;
        end
        if (errs2 < best) begin best = errs2; bestlag = j; end
      end
      $display("  arm delay %0d clk : status %h (idx %0d, phase %0d) | back-to-back %0d | per-sample %0d bad | const lag %0d: %0d bad",
               ph, stat, stat[7:0], stat[13:10], pv, errs, bestlag, best);
    end

    for (sweep = 0; sweep < 7; sweep = sweep + 1) begin
      // the same seven points the hardware sweep used, by FPGA1 divisor
      case (sweep)
        0: bper = 20;   // div 40, bclk  25.0 MHz -> lclk 12.50
        1: bper = 16;   // div 32, bclk  31.2     -> lclk 15.62
        2: bper = 10;   // div 20, bclk  50.0     -> lclk 25.00
        3: bper = 8;    // div 16, bclk  62.5     -> lclk 31.25
        4: bper = 6;    // div 12, bclk  83.3     -> lclk 41.67
        5: bper = 5;    // div 10, bclk 100.0     -> lclk 50.00
        6: bper = 4;    // div  8, bclk 125.0     -> lclk 62.50
      endcase
      axi_write(32'h4000_0040, 32'h3);
      axi_write(32'h4000_0400, 32'h51);
      axi_write(32'h4001_0028, 32'hA);      // matched PN, frame-aligned
      axi_write(32'h4001_0020, 32'h0);
      #2000;
      axi_write(32'h4001_0020, 32'h1);
      #700000;
      axi_read(32'h4001_0024);
      $display("");
      $display("bclk half-period %0d ns -> lclk %0.2f MHz, capture status %h",
               bper, 1000.0/(4.0*bper), rdval);
      for (k=0;k<128;k=k+1) begin
        axi_read(32'h4001_0400 + k*4); ins[k]  = rdval[15:0];
        axi_read(32'h4001_0800 + k*4); outs[k] = rdval;
      end
      // how many samples were preceded by another valid? That is the duty
      // variation itself, measured rather than inferred.
      pv = 0;
      for (k=0;k<128;k=k+1) if (outs[k][24]) pv = pv + 1;
      errs = 0;
      for (k=N+2;k<128;k=k+1) begin
        lag = outs[k][24] ? 2 : 1;
        expect_ = 0;
        for (i=0;i<N;i=i+1) expect_ = expect_ + tp[i]*$signed(ins[k-lag-i]);
        if ($signed(outs[k][23:0]) !== $signed(expect_[ACC-1:0])) errs = errs + 1;
      end
      // and what a single constant lag would have concluded
      best = 9999;
      for (j=1;j<4;j=j+1) begin
        errs2 = 0;
        for (k=N+j;k<128;k=k+1) begin
          expect_ = 0;
          for (i=0;i<N;i=i+1) expect_ = expect_ + tp[i]*$signed(ins[k-j-i]);
          if ($signed(outs[k][23:0]) !== $signed(expect_[ACC-1:0])) errs2 = errs2 + 1;
        end
        if (errs2 < best) begin best = errs2; bestlag = j; end
      end
      $display("  back-to-back %0d/128 | per-sample lag: %0d bad | best constant lag %0d: %0d bad", pv, errs, bestlag, best);
    end
    $finish;
  end
  initial begin #90000000; $display("TIMEOUT"); $finish; end
endmodule
