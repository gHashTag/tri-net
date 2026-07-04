# Image-bake milestone — persistent per-board images (prerequisite for M2)

## Why this exists

The stock Puzhi P201Mini image is not usable for a three-board mesh:

- `root=/dev/ram0 rootfstype=ramfs` — `/etc` is RAM-only, runtime edits wiped
  on every cold power-cycle.
- Identical MAC `00:0a:35:00:01:22` on all three boards (Xilinx OUI, same
  address literally repeated), identical hostname `pzp201mini`, identical
  static IP `192.168.1.10`.
- Runtime MAC override breaks Zynq GEM (`macb`) TX checksum offload → bulk
  `scp` fails 10/10 attempts; `ethtool` is not installed on the stock image
  to disable the offload.

Five runtime workarounds failed on the bench 2026-07-04 (see
[`LOCAL_FLASH.md`](LOCAL_FLASH.md) §1.4 for the diagnosis; five paths:
IP-only via `.12`/`.13`, MAC spoof + IP, ethtool disable offload, MTU 576,
usb0 CDC-Ethernet gadget). Runtime is a dead wall.

The only remaining path is **image-level**: rebuild the initramfs so each
board boots with its own unique identity from the start, and put `smoke-m1`
into the baked image so no cross-board transfer is needed for M1 audit rows.

This is a prerequisite for M2 (routing, ETX, neighbor discovery — all
require boards to be identifiable on L2/L3). It is NOT a prerequisite for
Trinity silicon tape-out (Dec 2026) and is decoupled from the δ-paper work.

## Prerequisites (verified on dev Mac 2026-07-04)

- **Present on Mac**: `cpio`, `gzip`, `zstd`, `xxd`.
- **MISSING on Mac**: `mkimage` (from u-boot-tools). Install:
  `brew install u-boot-tools`.
- **MISSING on Mac**: SD-card reader (no external disk enclosure at hand).
  Two options:
  - **(a) Obtain reader.** Cheapest, safest, definitive. USB-C SD reader,
    any brand, ~5 USD.
  - **(b) In-place reflash from a running board via SSH.** `dd` the new
    `image.ub` (and if needed `BOOT.BIN` / rootfs) to the SD partition
    while the board is running the old copy, then reboot.
    **RISK: bricks the board if the wrong partition is written or `dd`
    is interrupted.** Do on ONE board first, keep two known-good boards
    as fallback. Do not attempt in-place reflash of BOOT.BIN — write to
    the rootfs partition only, or write a full image to a spare SD.
- **Image source** (on the platform, not on the Mac yet): pull
  `/boot/image.ub` and `/boot/BOOT.BIN` and `/boot/uEnv.txt` from board-1
  over SSH (`192.168.1.10` — the only board that is reliable). Board-1 is
  the reference build; boards 2/3 boot the same bytes.

Sandbox side (Perplexity Computer): `mkimage`, `cpio`, `dtc`, `zstd`, `gzip`
all available; can perform the repack step server-side if the raw image
files are shared into the repo (separate branch or `share_file`).

## Repack plan (linear)

1. **Extract** — pull `image.ub` from board-1 via SSH. Split with
   `mkimage -l image.ub` (u-boot legacy multi-image) into kernel + FDT +
   ramdisk components.
2. **Unpack ramdisk** — the ramdisk is a `gzip`ped `cpio` archive.
   `zcat ramdisk | cpio -id` into a workdir.
3. **Patch per-board** — for each `N ∈ {1, 2, 3}`:
   - Write `/etc/network/interfaces` with static IP `192.168.1.1N`
     (`.10` / `.12` / `.13`), locally-administered MAC `02:00:00:00:00:0N`,
     gateway `192.168.1.1`.
   - Write `/etc/hostname` = `tri-mini-N`.
   - Copy `smoke-m1` binary (`a17e88e6…` build) to `/root/smoke-m1`,
     `chmod +x`.
   - Verify `S21misc` still restores `authorized_keys` from
     `/mnt/jffs2/root/.ssh/` — do not break the persistent-SSH path from
     `LOCAL_FLASH.md` §1.4 (A). Alternatively, bake the host pubkey into
     `/root/.ssh/authorized_keys` directly in the image; jffs2 becomes
     optional then.
4. **Repack ramdisk** — `find . | cpio -o -H newc | gzip -9 > ramdisk.gz`.
   Preserve permissions and ownership (`--owner=root:root`).
5. **Repack image** — `mkimage` recombine kernel + FDT + new ramdisk into
   `image_boardN.ub`. Three artefacts total.
6. **Verify** — `mkimage -l image_boardN.ub` prints correct component sizes
   and CRCs. `sha256sum image_boardN.ub` recorded in
   `smoke/IMAGE_BAKE_<date>.md`.
7. **Flash** — either dd to three SD cards (needs reader) or in-place
   reflash one board at a time (needs SSH, needs the risk-tolerance above).

## Definition of Done

1. Three boards boot with **distinct** MAC / IP / hostname, **persistent
   across cold power-cycle**. Verified from Mac:

   ```bash
   sudo arp -d 192.168.1.10 2>/dev/null
   sudo arp -d 192.168.1.12 2>/dev/null
   sudo arp -d 192.168.1.13 2>/dev/null
   for h in tri-mini-1 tri-mini-2 tri-mini-3; do
     ssh root@$h 'hostname; ip -4 addr show eth0 | grep inet; ip link show eth0 | grep ether'
   done
   ```

   Three unique triplets, no ARP flux, no `scp` failures.

2. `smoke-m1` is on each board at `/root/smoke-m1`, sha256 matches
   `a17e88e6…`.

3. `for h in tri-mini-1 tri-mini-2 tri-mini-3; do ssh root@$h
   /root/smoke-m1; echo "$h RC=$?"; done` produces three RC=0 lines. Each
   line becomes a row in `smoke/M1_RESULTS.md` — one paperwork event, not
   three research events.

4. `scp` of a ≥ 500 KB file to each board succeeds without truncation
   (proves the GEM TX-offload path is now working with a real, unique,
   non-spoofed MAC).

5. `docs/LOCAL_FLASH.md` §0.5 warning banner is **updated** to say
   "persistent — image-bake milestone completed <date>, tag
   `image-bake-<date>`". Not removed — kept as history so the next
   operator understands why this file exists.

## Anti-scope (this milestone does NOT do)

- Does NOT add TUN, routing, ETX, or any M2 code path. That is
  `feat/m2-routing`, not this milestone.
- Does NOT touch AD9361 config. Radio work is `radio/` scope.
- Does NOT modify FSBL / bootloader / device tree. Only the ramdisk
  contents change; BOOT.BIN stays as shipped.
- Does NOT publish or claim silicon-signed anything. Still pre-silicon.

## Risk register

- **In-place reflash brick risk (path b):** do on one board first, keep
  two known-good as fallback. Do not write BOOT.BIN in-place.
- **Ramdisk size grows:** `smoke-m1` is 537 KB, well below any realistic
  ramdisk ceiling on Zynq-7020. Not a concern.
- **`mkimage` header mismatch:** verify header type / architecture / OS
  fields with `mkimage -l` on the original before repacking; mismatched
  header causes U-Boot to refuse the image at boot with `Bad Magic
  Number`. If seen, dump original with `dumpimage -T multi -p N` to
  recover exact component layout.
- **Persistent identity in `/mnt/jffs2/` instead of ramdisk:** an
  alternative to per-board images is one common image + per-board files in
  jffs2 (mtd2). This is `LOCAL_FLASH.md` §1.4 path (B1). Cleaner if the
  team wants one artefact instead of three, at the cost of writing the
  jffs2 partition on each board once (also needs some form of persistent
  write, but jffs2 is designed for it).

## Handoff

When ready to execute:

1. Boot board-1 with the stock image, `scp` `image.ub` / `BOOT.BIN` /
   `uEnv.txt` to the Mac (or push into a `image-source-2026-07-04` branch
   in this repo).
2. Decide path (a) SD-reader or (b) in-place reflash, or (B1) jffs2-only.
3. Open `feat/image-bake-<date>` branch; do NOT reuse
   `feat/persistent-ip-policy` (this is a scope separation issue).
4. Human-merge only per `docs/AUTONOMOUS.md`.

Anchor: φ² + φ⁻² = 3.
