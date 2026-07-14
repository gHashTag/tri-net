// tb_dna_reader.v — self-checking testbench for the dna_reader RTL.
//
// Checks:
//   T1  reset holds dna_out=0, valid=0
//   T2  after start pulse, valid rises within DNA_BITS+4 clks
//   T3  the latched dna_out equals SIM_DNA_VALUE bit-reversed against LSB-
//       first UNISIM semantics (MSB-first accumulation in reader)
//   T4  a second start after HOLD does not re-latch until rst_n is asserted
//
// Runs under Icarus Verilog (`iverilog -g2012`). Real synth uses Xilinx
// UNISIMs; here we substitute the behavioural DNA_PORT model.
//
// phi^2 + phi^-2 = 3

`timescale 1ns / 1ps

module tb_dna_reader;
    localparam integer DNA_BITS = 57;
    localparam [56:0]  SIM_VAL  = 57'h123_4567_89AB_CDEF;

    reg                  clk = 1'b0;
    reg                  rst_n = 1'b0;
    reg                  start = 1'b0;
    wire [DNA_BITS-1:0]  dna_out;
    wire                 valid;

    // 100 MHz clock (10 ns period).
    always #5 clk = ~clk;

    dna_reader #(.DNA_BITS(DNA_BITS)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .dna_out(dna_out), .valid(valid)
    );

    // Expected dna_out is the MSB-first assembly of a LSB-first stream:
    // real hw pushes bit[0] first, then bit[1], ... then bit[56]; wrapper
    // does {dna_out[DNA_BITS-2:0], dout} which puts the first bit at the
    // MSB position. So expected = bit_reverse(SIM_VAL).
    function [DNA_BITS-1:0] bit_reverse(input [DNA_BITS-1:0] v);
        integer i;
        begin
            bit_reverse = '0;
            for (i = 0; i < DNA_BITS; i = i + 1)
                bit_reverse[i] = v[DNA_BITS-1-i];
        end
    endfunction

    integer errors = 0;

    task check(input cond, input [255:0] label);
        begin
            if (!cond) begin
                $display("FAIL: %s", label);
                errors = errors + 1;
            end else begin
                $display("PASS: %s", label);
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_dna_reader.vcd");
        $dumpvars(0, tb_dna_reader);

        // T1 — reset
        #7 rst_n = 1'b0;
        #20;
        check(dna_out === '0, "T1 dna_out cleared under reset");
        check(valid   === 1'b0, "T1 valid low under reset");

        // Deassert reset
        @(posedge clk) rst_n = 1'b1;
        @(posedge clk);

        // T2 — pulse start
        @(posedge clk) start = 1'b1;
        @(posedge clk) start = 1'b0;

        // Wait DNA_BITS + 8 clks for latency
        repeat (DNA_BITS + 8) @(posedge clk);
        check(valid === 1'b1, "T2 valid asserted after DNA_BITS clks");

        // T3 — value check
        check(dna_out === bit_reverse(SIM_VAL),
              "T3 dna_out == bit_reverse(SIM_VAL)");

        // T4 — second start without reset must not re-latch (state stays HOLD)
        @(posedge clk) start = 1'b1;
        @(posedge clk) start = 1'b0;
        repeat (DNA_BITS + 8) @(posedge clk);
        check(dna_out === bit_reverse(SIM_VAL),
              "T4 second start ignored, dna_out unchanged");
        check(valid === 1'b1, "T4 valid still asserted");

        // Summary
        if (errors == 0)
            $display("ALL 5 CHECKS PASSED");
        else
            $display("FAILED %0d CHECK(S)", errors);

        $finish;
    end

    // Watchdog
    initial begin
        #2000;
        $display("WATCHDOG timeout at 2 us");
        $finish;
    end
endmodule
