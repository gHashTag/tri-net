# JTAG Bootstrap Tools for P201Mini (Zynq 7020)

Boot U-Boot via USB-JTAG (FTDI FT2232H) + openOCD, bypassing empty QSPI.

## Provenance

- **Tested**: 2026-07-06 on P201Mini, Zynq 7020 (xc7z020), 1GB DDR3
- **Source**: ps7_init adapted from PlutoSDR jtag-bootstrap v0.38
- **Conversion**: XSDB TCL → openOCD TCL (mask_write/mask_poll/mwr/mrd/mask_delay)
- **Verified**: DDR3 integrity 100% (write+read test, 100/100 words correct)
- **U-Boot**: PlutoSDR v0.38, loaded + executes in DDR

## Hardware

- Board: Puzhi P201Mini (Zynq 7020 + AD9361 + 1GB DDR3 + 256Mb QSPI)
- USB-JTAG chip: FTDI FT2232H (VID 0x0403, PID 0x6010)
- Channel A: JTAG (used by openOCD)
- Channel B: UART (115200 or ~1MHz depending on UART clock config)
- Boot mode switch: JTAG position

## Files

| File | Purpose |
|---|---|
| `ftdi_jtag.cfg` | openOCD FTDI interface config (VID 0x0403, PID 0x6010) |
| `ocd_helpers.tcl` | XSDB→openOCD compatibility layer (mask_write, mask_poll, mwr, mrd) |
| `ps7_init_openocd.tcl` | PS7 initialization (PLL + DDR3 + clocks + MIO) |
| `boot_uboot.ocd` | Full boot script: init → ps7_init → UART clock → load U-Boot → resume |

## Usage

```bash
# Install openOCD
brew install openocd    # macOS
# apt install openocd   # Linux

# Connect P201Mini via Type-C USB, boot switch → JTAG

# Boot U-Boot via JTAG
openocd -f tools/jtag-bootstrap/ftdi_jtag.cfg \
        -f <openocd-path>/share/openocd/scripts/target/zynq_7000.cfg \
        -c "adapter speed 5000" \
        -f tools/jtag-bootstrap/boot_uboot.ocd \
        -c "shutdown"
```

## Known issues (macOS)

- macOS USB stack prevents simultaneous JTAG (channel A) + UART (channel B) access on same FTDI device
- Workaround: boot U-Boot via JTAG, shutdown openOCD, then capture serial
- Linux allows simultaneous access — recommended for production use

## Next step after U-Boot

Once U-Boot is running (with UART access), flash QSPI:
```
sf probe 0 0 0
tftpboot 0x1000000 pluto.frm     # or loadb/xmodem
sf erase 0 0x800000
sf write 0x1000000 0 ${filesize}
```

phi^2 + phi^-2 = 3
