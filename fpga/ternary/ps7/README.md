# PS-driven ternary peripheral on Zynq-7020 -- 100% open flow to a bitstream

This closes the on-chip integration boundary that earlier docs called blocked.
`ps7_tern.v` instantiates the Zynq **PS7 hard block** and drives a ternary
sign-select MAC (the tri-net primitive) from the ARM PS -- no Vivado, no AXI IP,
no block design. It goes **all the way to a loadable xc7z020 bitstream** through
the fully open flow.

## What it is

- **PS7** provides the PL a clock (`FCLKCLK[0]`) and a 32-bit EMIO GPIO bus that
  Linux drives directly from `/sys/class/gpio` -- the simplest possible PS<->PL
  path, no custom AXI-Lite slave needed.
- The PS writes an 8-bit signed sample and a 2-bit ternary weight over `EMIOGPIOO`;
  a **sign-select MAC** computes `+x / -x / 0` in one LUT level (ZERO DSP, the same
  primitive as the radio despreader and the BitNet layer); the PS reads the result
  back over `EMIOGPIOI`. A heartbeat counter on the PS clock drives an LED to prove
  `FCLK` reaches the fabric.

## Measured through the open flow (regymm/openxc7, no Vivado)

| stage | tool | result |
|-------|------|--------|
| synthesis | yosys `synth_xilinx` | **PS7 blackbox + ternary MAC + FCLK, 0 problems** |
| place & route | nextpnr-xilinx | **PS7 BEL placed, FCLK routed, complete** |
| timing | nextpnr STA | **Fmax `FCLKCLK[0]` = 308 MHz** |
| FASM -> frames | prjxray `fasm2frames` | **7802 frames** |
| frames -> bit | `xc7frames2bit` | **`ps7_tern.bit` = 4,045,670 bytes** (correct full xc7z020 config size) |

So the whole chain **yosys -> nextpnr-xilinx -> fasm2frames -> xc7frames2bit**
produces a real, loadable, PS-driven bitstream. This refutes the earlier boundary
("openXC7 does not wire up the PS7/AXI boundary"): the open flow ships the yosys
`PS7` blackbox (`cells_xtra.v`), the prjxray-db `zynq7` PS-interface tiles
(`PSS0..4`, `INT_INTERFACE_PSS_L`), and the nextpnr `PS7_PS7` BEL -- and they work
together end to end.

Regenerate:
```
yosys -p "read_verilog ps7_tern.v; synth_xilinx -flatten; write_json ps7_tern.json"
nextpnr-xilinx --chipdb z020.bin --xdc ps7_tern.xdc --json ps7_tern.json --fasm ps7_tern.fasm
fasm2frames --db-root <prjxray-db>/zynq7 --part xc7z020clg400-1 ps7_tern.fasm ps7_tern.frames
xc7frames2bit --part_name xc7z020clg400-1 --frm_file ps7_tern.frames --output_file ps7_tern.bit
```
(The 4 MB `.bit` is not committed -- regenerate it; the SSOT is this source + flow.)

## Honest boundary (what is NOT done)

The bitstream is generated but **not loaded on a board**, on purpose. This
particular design uses auto-placed LED/EMIO pins (not the P201Mini's real pin and
EMIO-GPIO map) and has no PS-side test program, so loading it would configure the
PL, disconnect the live AD9361 radio, and demonstrate nothing verifiable -- a
destructive no-op. The meaningful on-silicon step is a focused follow-on: constrain
to the board's actual pins/EMIO, add a tiny PS program (devmem / gpio sysfs) that
writes a sample+weight and reads the MAC result, then flash reversibly. The flow
to a bitstream -- the part that was in doubt -- is now proven.
