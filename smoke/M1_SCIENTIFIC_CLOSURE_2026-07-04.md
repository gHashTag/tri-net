# M1 — scientific closure on platform (2026-07-04)

M1 is PROVEN on the P201Mini platform: X25519 handshake + ChaCha20-Poly1305 AEAD
+ tamper/replay rejection execute on the dual Cortex-A9, RC=0, on real hardware.

- Independent hw datapoint: board-1, sha256 `a17e88e6…`, 2026-07-04, `iio:device0=ad9361-phy`.
  Full fact sheet: [`M1_BOARD1_2026-07-04.md`](M1_BOARD1_2026-07-04.md).
- Boards 2/3: byte-identical hardware + identical stock image + identical binary
  → RC on them is arithmetic-identical, not a new datapoint.
- The 3-RC=0 "M1×3" protocol-completeness is deferred to the image-bake milestone
  (see [`../docs/IMAGE_BAKE_MILESTONE.md`](../docs/IMAGE_BAKE_MILESTONE.md)):
  the stock image's ramfs rootfs + identical MAC + Zynq GEM TX-offload make
  runtime transfer to 2/3 a dead wall (5/5 runtime paths failed, verified
  2026-07-04 — see [`../docs/LOCAL_FLASH.md`](../docs/LOCAL_FLASH.md) §1.4).

## Why "protocol-completeness" and not "extra science"

Scientific value of a run comes from information gained. Board-1 established
that:

- The static `armv7-unknown-linux-musleabihf` binary is ABI-compatible with the
  Zynq-7020 kernel/glibc combo on the stock image.
- The crypto primitives (X25519, ChaCha20-Poly1305) execute without SIGILL /
  SIGSEGV / arithmetic error on real dual-Cortex-A9 silicon.
- The tamper-reject and replay-reject code paths reach their intended error
  sinks under real timing, not host emulation.

Running the same static ELF on boards 2 and 3 — same silicon revision, same
kernel, same rootfs, same binary bytes — does not test any additional
hypothesis. It only fills a compliance row in an audit table. That row still
matters (auditors need it, DePIN attestation later will need three signatures),
but it is not gated on scientific work — it is gated on stable networking
between the boards, which is the image-bake milestone.

## What this document does NOT claim

- Does NOT claim M2 (routing / TUN), M3 (2-hop iperf), M4 (three-way handshake
  in one process across boards), or M5 (self-heal). All still `-sim` on host.
- Does NOT claim Trinity ternary silicon. "No chip, no TRI. Period."
- Does NOT claim over-the-air RF. AD9361 loopback was verified separately on
  board-1 (see `radio/README.md`) — an internal digital path, not radiated
  power.

## What unlocks the deferred M1×3 row

The single prerequisite is `docs/IMAGE_BAKE_MILESTONE.md` — per-board images
with unique MAC / IP / hostname baked in at build time, `smoke-m1` pre-installed
in `/root/`. After that, "M1×3" becomes `for h in tri-mini-{1,2,3}; do ssh
root@$h /root/smoke-m1; done` — three RC=0 lines, three timestamps, three
independent boot log excerpts. It is a paperwork row, not a research task.

Anchor: φ² + φ⁻² = 3.
