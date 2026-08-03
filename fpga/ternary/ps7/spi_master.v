`timescale 1ns/1ps
// spi_master -- the shift engine for the radio's control plane.
//
// Why this exists. Cycle 41 established, by measurement, that the AD9361 is
// unreachable from the processor except through the PL: `spi_csn`, `spi_clk`
// and `spi_mosi` are FPGA outputs in the vendor design, as are `gpio_resetb`,
// `enable` and `txnrx`. A bitstream with no outputs -- which is what made every
// design here safe to load -- severs all of them at once, and the register
// reads duly went from sensible to all-zero.
//
// The vendor design passes the PS SPI controller through to those pins. This
// does the same job with a fabric master driven from AXI instead, because the
// software side here is `devmem` rather than a driver, and a register write is
// a great deal easier to issue than a configured SPI controller.
//
// SCOPE, stated rather than implied: this shifts words. It does not know the
// AD9361's command format -- how many bits are address, which bit is read
// versus write, how a multi-byte burst is framed. That belongs in software and
// must come from the datasheet or the Linux driver, not from a guess here. A
// master and a slave model that agree only with each other would prove nothing
// about the real part.
//
// CPOL = 0, CPHA = 0: clock idles low, MOSI changes on the falling edge, MISO
// is sampled on the rising edge. That is what the AD9361 expects and what
// ADI's own designs use.

module spi_master #(
  parameter WIDTH = 24,          // bits per transaction
  parameter DIV   = 8            // sclk = clk / (2*DIV)
) (
  input                    clk,
  input                    rstn,

  // control, from AXI
  input                    start,      // one-cycle pulse
  input      [WIDTH-1:0]   wdata,
  output reg [WIDTH-1:0]   rdata = 0,
  output reg               busy = 1'b0,
  output reg               done = 1'b0,  // one-cycle pulse

  // pins
  output reg               spi_csn = 1'b1,
  output reg               spi_clk = 1'b0,
  output reg               spi_mosi = 1'b0,
  input                    spi_miso
);

  localparam CNTW = (DIV <= 1) ? 1 : $clog2(DIV);

  reg [CNTW-1:0]      div_cnt = 0;
  reg [WIDTH-1:0]     shift_out = 0;
  reg [WIDTH-1:0]     shift_in = 0;
  reg [$clog2(WIDTH*2+4)-1:0] bit_cnt = 0;
  reg                 phase = 1'b0;      // 0: about to drive, 1: about to sample

  wire tick = (div_cnt == DIV-1);

  always @(posedge clk) begin
    done <= 1'b0;
    if (!rstn) begin
      busy <= 1'b0; spi_csn <= 1'b1; spi_clk <= 1'b0; spi_mosi <= 1'b0;
      div_cnt <= 0; bit_cnt <= 0; phase <= 1'b0;
    end else if (!busy) begin
      spi_clk <= 1'b0;
      if (start) begin
        busy      <= 1'b1;
        shift_out <= wdata;
        shift_in  <= 0;
        bit_cnt   <= 0;
        div_cnt   <= 0;
        phase     <= 1'b0;
        spi_csn   <= 1'b0;
        // CPHA = 0: the first bit must be valid before the first rising edge
        spi_mosi  <= wdata[WIDTH-1];
      end
    end else begin
      div_cnt <= tick ? {CNTW{1'b0}} : div_cnt + 1'b1;
      if (tick) begin
        if (!phase) begin
          // rising edge: the slave samples MOSI, we sample MISO
          spi_clk  <= 1'b1;
          shift_in <= {shift_in[WIDTH-2:0], spi_miso};
          phase    <= 1'b1;
        end else begin
          // falling edge: advance MOSI, or finish
          spi_clk <= 1'b0;
          phase   <= 1'b0;
          if (bit_cnt == WIDTH-1) begin
            spi_csn <= 1'b1;
            busy    <= 1'b0;
            done    <= 1'b1;
            rdata   <= shift_in;
          end else begin
            shift_out <= {shift_out[WIDTH-2:0], 1'b0};
            spi_mosi  <= shift_out[WIDTH-2];
            bit_cnt   <= bit_cnt + 1'b1;
          end
        end
      end
    end
  end

endmodule
