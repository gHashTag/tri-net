# scripts/m2/ — M2 image-bake preparation

Prep-track artifacts for **Option A** (M2 milestone: TUN + ETX on 3 physical
boards, image-bake unblock). Nothing here executes hardware operations from
the sandbox; every mutating step is skeleton or `DRY_RUN=1` guarded.

## Status

- **Executor:** Mac / cloud with a physical SD-card reader attached AND
  a stock bootable image `.ub` from the board vendor.
- **Blocker:** SOURCE MATERIALS, not just SD-reader. See findings below.
- **Anchor:** `phi^2 + phi^-2 = 3`

## Findings (2026-07-04, live board probe)

Direct inspection of a running Puzhi board revealed the target hardware
is NOT a "modify existing image" workflow. Evidence from `dmesg` +
`mtd` + U-Boot env on the live board:

- `mmc0: SDHCI controller on e0100000.mmc` — SD controller present, but
  no "new SD card" event: the board does NOT read boot media from SD in
  its default state.
- `mtd3` (`qspi-linux`, 30 MB, the QSPI-flash boot partition) reads all
  `0xff` — the persistent boot storage is EMPTY.
- `bootcmd: bootp; ... bootm` — the board boots over the network via
  DHCP/TFTP. Kernel + ramfs land in RAM from an external server and are
  lost at power-cycle.

Consequence: there is no `stock-image.ub` on the board to dump, unpack,
inject, and repack. W4 is not `bake existing image` — it is
`create bootable QSPI image from scratch`, which requires:

1. `zImage` (kernel binary) — either extracted from the running RAM
   image or obtained from the Puzhi SDK / firmware source.
2. DTB — from `/proc/device-tree`, `/sys/firmware/fdt`, or SDK.
3. Rootfs cpio — created from the running rootfs plus the board-unique
   MAC and the smoke-m1 payload.
4. `mkimage` package the three components into a FIT image, then
   `flashcp` (or `sf write` under U-Boot) to `mtd3`.
5. U-Boot env change:
   `setenv bootcmd 'sf probe; sf read 0x100000 0x200000 0x1e00000; bootm 0x100000'`
   so future boots read from QSPI, not the network.

Alternative unblock (much simpler if the vendor cooperates): a physical
SD card with a ready-made bootable image + a boot-mode pin change to
SD-boot instead of QSPI-boot. This preserves the current skeleton as-is
because `bake-image.sh` then IS "modify existing image".

## Unblock preconditions (any one is sufficient)

1. **Puzhi SDK / firmware source** — turns W4 into a ~1-week runbook.
2. **Vendor-supplied bootable SD image** — turns W4 into the current
   skeleton, executed once per board.
3. **Reverse-engineer kernel + dtb from live RAM** — technically
   feasible but licensing- and reproducibility-unclear; not recommended.

Until one of (1) or (2) is available, the `bake-image.sh` skeleton is
correct for the "modify existing image" case and remains parked here as
a runbook; no further work in this directory unblocks anything.

## Contents

| File | Purpose |
|---|---|
| `bake-image.sh` | 8-stage skeleton: verify → dump → unpack → inject MAC + smoke-m1 → repack → mkimage → verify → flash (guarded). |
| `README.md` | This file. |

## Runbook (planned, once hardware is attached)

Per-board sequence, three boards total:

```bash
# 1. Bake image for board 01
DRY_RUN=1 ./scripts/m2/bake-image.sh \
    --input  ./artifacts/stock-image.ub \
    --mac    52:54:00:00:00:01 \
    --smoke  ./artifacts/smoke-m1 \
    --output ./artifacts/board-01.ub

# 2. Repeat for boards 02, 03 with distinct MACs.

# 3. Flash board 01 first — verify boots and smoke-m1 completes.
DRY_RUN=0 SD_DEVICE=/dev/disk4 ./scripts/m2/bake-image.sh --flash \
    --image ./artifacts/board-01.ub

# 4. Only after board 01 is confirmed healthy: flash 02 and 03.
```

The three-board sequence intentionally reflashes **one board first** and
proves it boots before touching the other two, to keep the blast radius
of a bad bake at 1 board rather than 3.

## Gaps to fill on the executor machine

The skeleton contains explicit `TODO:` markers for each stage. Filling
them requires facts that only the executor has:

1. **FIT vs legacy uImage layout** of the stock image — determines
   `dumpimage`/`mkimage` flags.
2. **Target architecture** (`-A arm`, `-A arm64`, etc.) — read from
   `dumpimage -l stock-image.ub`.
3. **Rootfs init hook location** — `/etc/rc.local` vs `/etc/init.d/*`
   vs systemd unit — depends on the distro on the stock image.
4. **SD-card device path** — `/dev/disk4` on Mac, `/dev/sdX` on Linux;
   confirm with `diskutil list` or `lsblk` before flashing.

## Non-claims

- This directory does not make M2 done.
- It does not perform any hardware operation from CI or from the sandbox.
- `DRY_RUN=0` in `bake-image.sh` deliberately refuses to execute; the
  final flash sequence must be written by the executor with the stock
  image in hand, not guessed remotely.

phi^2 + phi^-2 = 3
