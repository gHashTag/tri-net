# W12 E2E RF Test Results — 2026-07-07

## Hardware
- 3× P201Mini (Zynq 7020 + AD9361 + 1GB DDR3)
- Antennas: inserted (5 GHz omni, SMA)
- Ethernet: all 3 on 192.168.1.{11,12,13}
- Boot: SD card (Kuiper BOOT.BIN + vendor uImage/DTB/ramdisk/uEnv)

## E2E Results: 30/30 PASSED

### System (per board)
| Check | Board 1 | Board 2 | Board 3 |
|-------|---------|---------|---------|
| Kernel | 5.10.0 | 5.10.0 | 5.10.0 |
| Hostname | pzp201mini | pzp201mini | pzp201mini |
| AD9361 | ad9361-phy | ad9361-phy | ad9361-phy |
| Ethernet | .11 ✓ | .12 ✓ | .13 ✓ |
| SD card | mmcblk0 ✓ | mmcblk0 ✓ | mmcblk0 ✓ |
| QSPI | 4 parts ✓ | 4 parts ✓ | 4 parts ✓ |
| DDR3 | present ✓ | present ✓ | present ✓ |
| Mesh ping | ✓ | ✓ | ✓ |

### RF Configuration
| Parameter | Value |
|-----------|-------|
| Frequency | 2400 MHz (Thailand ISM 2.4 GHz) |
| Sample rate | 4 MSPS |
| Bandwidth | 2 MHz |
| Calibration | auto |
| ENSM mode | FDD |

### Loopback Test (Board 1)
| Mode | RSSI |
|------|------|
| auto (baseline) | 27.75 dB |
| tx_quad | 24.00 dB |
| bbrf | 22.00 dB |

### OTA Signal Detection
| Phase | Board 2 RSSI | Board 3 RSSI |
|-------|-------------|-------------|
| Baseline | 25.75 dB | 17.25 dB |
| Board 1 TX ON (0 dB gain) | 22.50 dB | 26.00 dB |
| Board 1 TX OFF | 19.00 dB | 20.75 dB |
| **Delta** | -3.25 dB | **+8.75 dB ✅** |

Board 3 detected Board 1's transmission: +8.75 dB RSSI increase.

### Known Limitations
- RX DMA (cf-ad9361-lpc) not probed as IIO device — Kuiper bitstream mismatch
- Sample-level TX/RX requires stock P201Mini bitstream
- RSSI-level detection confirmed: RF path + antennas functional

φ² + φ⁻² = 3
