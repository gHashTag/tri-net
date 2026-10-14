# W13 — AX7203 + AN430 LCD Bring-up VICTORY (2026-07-12)

phi^2 + phi^-2 = 3

## Status: RESOLVED — color bars displayed on 4.3" TM043NBH02 panel

After a 20+ hour marathon spanning 35+ bitstreams, the AN430 LCD module now displays
color bars driven by the AX7203 board via openXC7 opensource toolchain.

## Root cause (three-part failure, single hidden anchor)

The primary anchor: **using the wrong vendor's reference design**. The AN430 module
ships with an Altera Cyclone IV E (`EP4CE6F17C8`, Quartus 14.1, 2015) demo. That demo
was ported to Xilinx with pin-map corrections but the timing/electrical conventions
were inherited unchanged. Three settings baked into the Altera port were silently wrong
for the AX7203 (Xilinx Artix-7) + AN430 combination:

1. **DCLK polarity**: Altera demo drives `assign lcd_dclk = clk_lcd` (non-inverted).
   Correct on AX7203+AN430: `assign lcd_dclk = ~lcd_clk`. Without the inversion the
   TCON latches data on the wrong edge → all pixels resolve to the same default
   value (white matrix).
2. **HSYNC/VSYNC drive strength**: Altera demo uses `assign lcd_hsync = 1'bz` and
   `assign lcd_vsync = 1'bz` (high-Z, letting the panel float or pull internally).
   Correct on AX7203+AN430: actively drive both from registered signals `hsync_r`
   and `vsync_r`.
3. **Blanking periods**: Altera demo uses back-porch H=45 V=16 with total periods
   288 lines / 525 pix. Correct on AX7203+AN430: H_BackPorch=2, V_BackPorch=2,
   FramePeriod=286. The Altera numbers cause the TCON to reject the frame.

## The correct reference

`https://github.com/alinxalinx/AX7103/blob/master/SRC/08_lcd_test/src/lcd_test.v`

This is the ALINX-official Vivado/Xilinx demo for AX7103, a sibling board of AX7203
sharing the J11 layout for the AN430 interposer. It uses the correct DCLK inversion,
active sync drive, and blanking numbers.

## Working configuration (verified 2026-07-12)

### Timing parameters
```verilog
parameter LinePeriod   = 525;
parameter H_SyncPulse  = 41;
parameter H_BackPorch  = 2;
parameter H_ActivePix  = 480;
parameter H_FrontPorch = 2;
parameter Hde_start    = 43;   // = H_SyncPulse + H_BackPorch
parameter Hde_end      = 523;  // = Hde_start + H_ActivePix

parameter FramePeriod  = 286;
parameter V_SyncPulse  = 10;
parameter V_BackPorch  = 2;
parameter V_ActivePix  = 272;
parameter V_FrontPorch = 2;
parameter Vde_start    = 12;
parameter Vde_end      = 284;
```

### Sync/DE drive
```verilog
assign lcd_dclk  = ~lcd_clk;   // MUST be inverted
assign lcd_hsync = hsync_r;    // ACTIVE, not 1'bz
assign lcd_vsync = vsync_r;    // ACTIVE, not 1'bz
assign lcd_de    = hsync_de & vsync_de;
```

### Pinout (verified against ALINX AX7203 UM page 49 + prjxray-db XC7A200T-FBG484-2)
```
lcd_r[7:0]  = T16 U16 P17 N17 P15 R16 R17 P16    (J11 pins 10..3)
lcd_g[7:0]  = V20 U20 V19 V18 R19 P19 U18 U17    (J11 pins 18..11)
lcd_b[7:0]  = Y11 Y12 V10 W10 AA11 AA10 AB10 AA9 (J11 pins 26..19)
lcd_dclk    = W12     (J11 pin 27)
lcd_hsync   = W11     (J11 pin 28)
lcd_de      = AB15    (J11 pin 29)
lcd_vsync   = AA15    (J11 pin 30)
```
All LVCMOS33, Bank 13.

### Clock generation (MMCM primitive since openXC7 has no Vivado IP wizard)
```verilog
IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) u_ibufg (
    .I(sys_clk_p), .IB(sys_clk_n), .O(sys_clk_ibufg)
);
MMCME2_BASE #(
    .CLKIN1_PERIOD(5.0),       // 200 MHz differential input R4/T4
    .DIVCLK_DIVIDE(1),
    .CLKFBOUT_MULT_F(5.0),     // VCO 1 GHz
    .CLKOUT0_DIVIDE_F(111.0)   // ~9.0 MHz for 480x272 @ ~60 Hz
) u_mmcm (
    .CLKIN1(sys_clk_ibufg),
    .CLKFBIN(mmcm_fb), .CLKFBOUT(mmcm_fb),
    .CLKOUT0(mmcm_clkout),
    .LOCKED(mmcm_locked),
    .RST(~rst_n), .PWRDWN(1'b0)
);
BUFG u_bufg (.I(mmcm_clkout), .O(lcd_clk));
```

## Toolchain (openXC7, fully open-source, no Vivado dependency)

```bash
# On dev machine (macOS or Linux with Docker)
cd .../video-ax7203/build_lcd_j13
bash build_official_port.sh
# Runs Docker regymm/openxc7 → yosys → nextpnr-xilinx → fasm2frames → xc7frames2bit
openFPGALoader --board alinx_ax7203 --cable digilent_hs3 lcd_official_port.bit
# Expect: isc_done 1, init 1, done 1 → color bars appear on LCD
```

## Lesson learned (add to hardware-bringup skill as Trap I)

**Trap I — Vendor-Reference Anchor**

Symptom: hardware exhibits identical failure mode across 30+ config permutations
(timing, mode, frequency, pin-mapping). LEDs and other GPIO work. Reference code
"looks right" and was ported carefully.

Mechanism: reference code was written for a DIFFERENT FPGA vendor (Altera ↔ Xilinx,
or Lattice ↔ Xilinx). Pin numbers were re-mapped but vendor-specific electrical
conventions (clock polarity default, high-Z vs. active drive, blanking assumptions)
were not adjusted.

Diagnostic (0 cost, 30 minutes):
1. Check the reference project file extension. `.qsf/.qpf/.sof` = Altera Quartus.
   `.xdc/.xpr/.bit` = Xilinx Vivado. `.lpf/.ldf` = Lattice Diamond. If the reference
   is not your target vendor, STOP and find the vendor-native reference before
   iterating on hardware.
2. Search `github.com/alinxalinx` (or the equivalent official-vendor org for your
   board maker) for a demo written in your target vendor's toolchain. This will
   have the correct sync polarity, drive strength, and blanking numbers baked in.
3. If no vendor-native reference exists, treat the port as `-sim` and cross-check
   each electrical convention against the target vendor's datasheet before
   flashing.

Fix: import the vendor-native reference. Do not iterate on the ported version.

Documented example: 2026-07-11..12 AX7203 + AN430 LCD bring-up.

## Post-mortem quantities

- Time spent on wrong path: ~20 hours across 2 sessions.
- Bitstreams built and flashed: 35+ variants (timing permutations, pin mapping A-H,
  RGB modes, camera-based pixel analysis).
- Sandbox-verified findings that were correct but not sufficient:
  - openXC7 flow is standard (verified against `scripts/fpga/build.sh` in t27).
  - All 30 XDC pins are valid on XC7A200T-FBG484-2 (verified via prjxray-db).
  - J11 pinout in XDC matches ALINX AX7203 UM page 49 in 28/28 comparable cells.
- The single insight that ended the marathon: `~lcd_clk` (one tilde in Verilog).

## References

- ALINX AX7103 official LCD demo (Xilinx/Vivado):
  https://github.com/alinxalinx/AX7103/blob/master/SRC/08_lcd_test/src/lcd_test.v
- ALINX AX7203 User Manual, Part 3.9 J11 Expansion Header, page 49
- prjxray-db XC7A200T-FBG484-2 package_pins.csv:
  https://github.com/f4pga/prjxray-db/blob/master/artix7/xc7a200tfbg484-2/package_pins.csv
- TM043NBH02 4.3" LCD datasheet §7 power-on sequence

phi^2 + phi^-2 = 3
