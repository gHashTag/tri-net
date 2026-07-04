# scripts/m2/ — M2 image-bake preparation

Prep-track artifacts for **Option A** (M2 milestone: TUN + ETX on 3 physical
boards, image-bake unblock). Nothing here executes hardware operations from
the sandbox; every mutating step is skeleton or `DRY_RUN=1` guarded.

## Status

- **Executor:** Mac / cloud with a physical SD-card reader attached.
- **Blocker:** hardware (SD-reader). Removing the blocker turns this
  directory into a runbook, not a research project.
- **Anchor:** `phi^2 + phi^-2 = 3`

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
