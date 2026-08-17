`timescale 1ps/1ps
// Checks two things a naive replacement gets wrong: the ARITHMETIC (signed,
// full width) and the LATENCY (exactly three, not two or four). Corner values
// first, then a pseudo-random sweep with a deterministic LFSR so the run is
// reproducible.
module ad_mul_open_tb;
  localparam AW = 17, BW = 17, PW = AW + BW;
  reg clk = 0; always #5 clk = ~clk;

  reg  signed [AW-1:0] a = 0;
  reg  signed [BW-1:0] b = 0;
  wire        [PW-1:0] p;
  reg  [15:0] din = 0; wire [15:0] dout;

  ad_mul_open #(.A_DATA_WIDTH(AW), .B_DATA_WIDTH(BW)) uut
    (.clk(clk), .data_a(a), .data_b(b), .data_p(p), .ddata_in(din), .ddata_out(dout));

  // expected value, delayed by exactly three clocks
  reg signed [PW-1:0] e1 = 0, e2 = 0, e3 = 0;
  always @(posedge clk) begin
    e1 <= a * b;
    e2 <= e1;
    e3 <= e2;
  end

  integer i, errors = 0, checked = 0;
  reg [31:0] lfsr = 32'hACE1_2345;
  reg armed = 0;

  always @(posedge clk) begin
    if (armed) begin
      checked = checked + 1;
      if (p !== e3) begin
        errors = errors + 1;
        if (errors <= 5)
          $display("  MISMATCH at check %0d: dut=%0d expected=%0d", checked, $signed(p), e3);
      end
    end
  end

  localparam signed [AW-1:0] AMAX =  (1 <<< (AW-1)) - 1;
  localparam signed [AW-1:0] AMIN = -(1 <<< (AW-1));

  initial begin
    @(negedge clk);
    // corners: the values where sign handling breaks if it is going to
    a = 0;    b = 0;    @(negedge clk);
    a = AMAX; b = AMAX; @(negedge clk);
    a = AMIN; b = AMIN; @(negedge clk);
    a = AMIN; b = AMAX; @(negedge clk);
    a = -1;   b = 1;    @(negedge clk);
    a = -1;   b = -1;   @(negedge clk);
    armed = 1;
    for (i = 0; i < 4000; i = i + 1) begin
      lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      a = lfsr[AW-1:0];
      lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      b = lfsr[BW-1:0];
      din = lfsr[15:0];
      @(negedge clk);
    end
    $display("ad_mul_open: %0d checked, %0d errors", checked, errors);
    $display(errors == 0 ? "=== PASS: signed product and 3-cycle latency both exact ==="
                         : "=== FAIL ===");
    $finish;
  end
endmodule
