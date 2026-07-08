# Per-board uEnv.txt (P201Mini SD boot)

uEnv-boardN.txt = stock vendor uEnv.txt (ZIP 001, 03.Boot Test/SD-BOOT/) with
exactly two changes:

1. Line 21: `ethaddr=02:00:00:00:00:0N` — U-Boot patches the FDT, Linux gets a
   unique MAC per board.
2. Line 56 (appended): `bootargs=console=ttyPS0,115200n8 root=/dev/ram rw
   earlyprintk ip=192.168.1.1N::192.168.1.1:255.255.255.0::eth0:off` — the
   stock `sdboot` passes `${bootargs}` (imported from uEnv.txt) to bootm, so
   the kernel brings up eth0 at 192.168.1.1N as primary. Survives reboot.

Proven on hardware 2026-07-08: all 3 boards booted with unique MAC+IP,
M1 crypto smoke 3/3, M2 three-board mesh convergence PASS
(smoke/M2_TWO_BOARD_RESULTS.md).

## NEVER do this

- `uenvcmd=` / `boardargs=` in uEnv.txt: `sdboot -> uenvboot -> uenvcmd ->
  sdboot` is an INFINITE RECURSION and hangs the board in U-Boot
  (SOUL.md Article V; docs/W12_FULL_TROUBLESHOOTING_REPORT.md P5).
  Earlier revisions of these files carried that pattern — do not resurrect it.
- Two SD cards with the same `ethaddr` on one switch: MAC-table flapping
  drops every session ("board boots then dies" symptom).
- Do not modify uramdisk.image.gz (mkimage CRC mismatch, boot fails).

## Flashing (macOS)

```
diskutil eraseDisk "MS-DOS FAT32" BOOT MBRFormat /dev/diskN
cp BOOT.bin uImage devicetree.dtb uramdisk.image.gz /Volumes/BOOT/
cp tools/board-configs/uEnv-boardN.txt /Volumes/BOOT/uEnv.txt
rm -rf /Volumes/BOOT/.Spotlight-V100 /Volumes/BOOT/.fseventsd
diskutil eject /dev/diskN
```

Binary sources: BOOT.bin/uImage from ZIP 001, devicetree.dtb/uramdisk.image.gz
from ZIP 002 (both under P201Mini_P203Mini/03.Boot Test/SD-BOOT/).
Insert SD before power-on; cold power-cycle only.
