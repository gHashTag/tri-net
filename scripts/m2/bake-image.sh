#!/usr/bin/env bash
# scripts/m2/bake-image.sh
# ------------------------------------------------------------------------------
# M2 image-bake skeleton — take a stock board image, inject a unique MAC and
# the smoke-m1 payload, repack into a bootable image.
#
# Status:            SKELETON (Option A prep, NOT hardware-executed from sandbox).
# Target executor:   Mac / cloud with an SD-card reader physically present.
# Author:            sandbox prep track, feat/m2-image-bake-prep.
# Anchor:            phi^2 + phi^-2 = 3
# ------------------------------------------------------------------------------
#
# WHY THIS EXISTS
# ---------------
# The M2 milestone (TUN + ETX on 3 boards) is blocked on hardware image-bake:
# each board needs a distinct MAC and a smoke-m1 payload burned into its
# ramfs before boot. Bake is impossible from the sandbox (no SD-card reader,
# no direct board access). This script formalizes the bake procedure so that
# when a reader is attached to a Mac, execution is a matter of running the
# script per board — not reinventing the sequence each time.
#
# HARD RULES (Trinity)
# --------------------
# - No chip, no TRI. This script does not claim M2 is done; it prepares
#   the exact steps that will run when M2 is unblocked.
# - Every mutating step is guarded by DRY_RUN=1 by default. Set DRY_RUN=0
#   only when you intend to actually reflash a physical board.
# - No emojis in output. No ! in body messages.
# - Every board flash must verify the image after write, before boot.
#
# USAGE (planned)
# ---------------
#   DRY_RUN=1 ./scripts/m2/bake-image.sh \
#       --input  ./artifacts/stock-image.ub \
#       --mac    52:54:00:00:00:01 \
#       --smoke  ./artifacts/smoke-m1 \
#       --output ./artifacts/board-01.ub
#
#   DRY_RUN=0 SD_DEVICE=/dev/disk4 ./scripts/m2/bake-image.sh --flash \
#       --image ./artifacts/board-01.ub
#
# DEPENDENCIES (Mac / Linux executor)
# -----------------------------------
#   - u-boot-tools (mkimage, dumpimage)   — brew install u-boot-tools
#   - cpio, gzip                          — coreutils / stock
#   - dd, sync, diskutil (Mac) or lsblk   — stock
#   - sha256sum / shasum                  — stock
#
# STAGES
# ------
#   1. verify-input    Sanity-check input image + smoke payload + MAC syntax.
#   2. dump-ramfs      dumpimage input.ub, extract compressed ramfs.
#   3. unpack-ramfs    gunzip + cpio -id into a scratch dir.
#   4. inject          Write MAC to /etc/board-mac; drop smoke-m1 into /usr/local/bin;
#                      make it executable; register autostart hook.
#   5. repack-ramfs    cpio -o | gzip -9 into a fresh ramfs.gz.
#   6. mkimage         Wrap ramfs.gz + kernel into a new .ub with mkimage,
#                      preserve arch/os/type/compression fields from input.
#   7. verify-output   sha256 output.ub; diff structural fields vs input.
#   8. flash           (optional, DRY_RUN=0 only) dd to SD_DEVICE with
#                      block-size 4M, then dd back and sha256-compare.
#
# ------------------------------------------------------------------------------

set -euo pipefail

# ------------------------------------------------------------------------------
# Config (defaults — override via env or flags)
# ------------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-1}"
SD_DEVICE="${SD_DEVICE:-}"
SCRATCH="${SCRATCH:-$(mktemp -d -t m2-bake-XXXXXX)}"

INPUT=""
MAC=""
SMOKE=""
OUTPUT=""
DO_FLASH=0
IMAGE=""

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log()  { printf '[bake] %s\n' "$*" >&2; }
step() { printf '[bake] === %s ===\n' "$*" >&2; }
die()  { printf '[bake] FATAL: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Args
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)  INPUT="$2";  shift 2;;
    --mac)    MAC="$2";    shift 2;;
    --smoke)  SMOKE="$2";  shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    --flash)  DO_FLASH=1;  shift;;
    --image)  IMAGE="$2";  shift 2;;
    -h|--help)
      sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) die "unknown flag: $1";;
  esac
done

# ------------------------------------------------------------------------------
# Stage 1 — verify-input
# ------------------------------------------------------------------------------
verify_input() {
  step "verify-input"
  [[ -n "$INPUT"  ]] || die "--input required"
  [[ -n "$MAC"    ]] || die "--mac required"
  [[ -n "$SMOKE"  ]] || die "--smoke required"
  [[ -n "$OUTPUT" ]] || die "--output required"

  [[ -f "$INPUT" ]] || die "input image not found: $INPUT"
  [[ -f "$SMOKE" ]] || die "smoke payload not found: $SMOKE"
  [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] \
    || die "MAC has wrong syntax: $MAC (expected xx:xx:xx:xx:xx:xx)"

  command -v mkimage    >/dev/null || die "mkimage not on PATH (brew install u-boot-tools)"
  command -v dumpimage  >/dev/null || die "dumpimage not on PATH"
  command -v cpio       >/dev/null || die "cpio not on PATH"

  log "input:  $INPUT ($(wc -c <"$INPUT") bytes)"
  log "mac:    $MAC"
  log "smoke:  $SMOKE ($(wc -c <"$SMOKE") bytes)"
  log "output: $OUTPUT"
  log "scratch: $SCRATCH"
}

# ------------------------------------------------------------------------------
# Stage 2 — dump-ramfs (TODO: fill exact dumpimage invocation per board FIT layout)
# ------------------------------------------------------------------------------
dump_ramfs() {
  step "dump-ramfs (STUB — needs FIT layout of target image)"
  # dumpimage -T flat_dt -p 1 -o "$SCRATCH/ramfs.gz" "$INPUT"
  log "TODO: exact dumpimage flags depend on whether image is legacy uImage or FIT."
  log "TODO: extract kernel blob to $SCRATCH/kernel for later repack."
}

# ------------------------------------------------------------------------------
# Stage 3 — unpack-ramfs
# ------------------------------------------------------------------------------
unpack_ramfs() {
  step "unpack-ramfs (STUB)"
  # mkdir -p "$SCRATCH/rootfs"
  # ( cd "$SCRATCH/rootfs" && gunzip -c "$SCRATCH/ramfs.gz" | cpio -idm )
  log "TODO: gunzip + cpio -idm into $SCRATCH/rootfs"
}

# ------------------------------------------------------------------------------
# Stage 4 — inject MAC + smoke payload
# ------------------------------------------------------------------------------
inject() {
  step "inject (STUB)"
  # printf '%s\n' "$MAC" > "$SCRATCH/rootfs/etc/board-mac"
  # install -m 0755 "$SMOKE" "$SCRATCH/rootfs/usr/local/bin/smoke-m1"
  # cat >> "$SCRATCH/rootfs/etc/rc.local" <<'HOOK'
  # /usr/local/bin/smoke-m1 --once >/var/log/smoke-m1.log 2>&1 &
  # HOOK
  log "TODO: write $MAC to /etc/board-mac"
  log "TODO: install smoke-m1 to /usr/local/bin/, chmod 0755"
  log "TODO: append autostart hook to /etc/rc.local"
}

# ------------------------------------------------------------------------------
# Stage 5 — repack-ramfs
# ------------------------------------------------------------------------------
repack_ramfs() {
  step "repack-ramfs (STUB)"
  # ( cd "$SCRATCH/rootfs" && find . | cpio -o -H newc | gzip -9 > "$SCRATCH/ramfs.new.gz" )
  log "TODO: cpio -o -H newc | gzip -9 -> $SCRATCH/ramfs.new.gz"
}

# ------------------------------------------------------------------------------
# Stage 6 — mkimage wrap
# ------------------------------------------------------------------------------
mkimage_wrap() {
  step "mkimage (STUB)"
  # mkimage -A arm -O linux -T ramdisk -C gzip \
  #   -d "$SCRATCH/ramfs.new.gz" "$OUTPUT"
  log "TODO: mkimage -A <arch> -O linux -T ramdisk -C gzip -d ramfs.new.gz $OUTPUT"
  log "TODO: preserve arch/os/type flags from input dumpimage -l output"
}

# ------------------------------------------------------------------------------
# Stage 7 — verify-output
# ------------------------------------------------------------------------------
verify_output() {
  step "verify-output (STUB)"
  # dumpimage -l "$OUTPUT"
  # shasum -a 256 "$OUTPUT"
  log "TODO: dumpimage -l $OUTPUT, structural diff vs input"
  log "TODO: sha256 record for reproducibility ledger"
}

# ------------------------------------------------------------------------------
# Stage 8 — flash (guarded)
# ------------------------------------------------------------------------------
flash() {
  step "flash"
  [[ -n "$SD_DEVICE" ]] || die "SD_DEVICE not set (e.g. /dev/disk4 on Mac)"
  [[ -f "$IMAGE"     ]] || die "--image not found: $IMAGE"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1: would dd if=$IMAGE of=$SD_DEVICE bs=4m"
    log "DRY_RUN=1: would sync and re-read for sha256 verification"
    return 0
  fi

  die "DRY_RUN=0 path is intentionally not implemented in the skeleton. \
Fill this in only after the input FIT layout, target arch, and reader \
device are all confirmed on the executor machine. Refuse to brick a board \
by autopilot."
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
if [[ "$DO_FLASH" == "1" ]]; then
  flash
else
  verify_input
  dump_ramfs
  unpack_ramfs
  inject
  repack_ramfs
  mkimage_wrap
  verify_output
  log "bake dry-run complete. Scratch left at $SCRATCH for inspection."
fi

# phi^2 + phi^-2 = 3
