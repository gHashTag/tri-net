# M1 smoke results — X25519 + ChaCha20-Poly1305

Milestone M1 (tri-net#10): crypto core running end-to-end. Two peers complete an
X25519 handshake, exchange a ChaCha20-Poly1305 sealed datagram, and prove tamper
and replay are rejected.

## Run log

| Date | Device | `uname -m` | Result | Status |
|---|---|---|---|---|
| 2026-07-01 | macOS host (aarch64-apple-darwin) | arm64 | 20 unit + 2 integration + smoke PASS | `-sim` |
| 2026-07-01 | Puzhi **P201Mini** · Zynq-7020, 2× Cortex-A9 | armv7l | `smoke-m1` PASS on-device (RC=0), sha256 `e5abc335…7290a` | ✅ **`hw`** |
| 2026-07-04 | Puzhi **P201Mini board-1** · Zynq-7020, 2× Cortex-A9 | armv7l | `smoke-m1` PASS on-device (RC=0), sha256 `a17e88e6…` — see [`M1_BOARD1_2026-07-04.md`](M1_BOARD1_2026-07-04.md) | ✅ **`hw`** |

### On-device run (2026-07-01) — **hw** ✅
Static `armv7-unknown-linux-musleabihf` binary (534,604 B, sha256 `e5abc335…7290a`) cross-built on macOS
(rustup rustc + bundled `rust-lld`, `-C target-feature=+crt-static`), streamed to the Mini over SSH and run:
```
host: Linux pzp201mini armv7l / 2 cores / iio:device0 name = ad9361
[M1] X25519 handshake complete: node 1 <-> node 2
[M1] AEAD round-trip OK: 44 bytes plaintext -> 79 bytes on-wire (ChaCha20-Poly1305)
[M1] tamper rejected: flipped tag bit -> Auth error
[M1] replay rejected: re-delivered frame -> Replay error
RC=0
```
The X25519 handshake + ChaCha20-Poly1305 AEAD + replay rejection execute on the real dual-Cortex-A9 flying node. M1 is now **hw**. (The binary's own "PASS (-sim)" string is stale build-time text — this run *is* the hardware graduation.)

### On-device run (2026-07-04) — **hw** ✅ (board-1, second datapoint)
Re-cut static `armv7-unknown-linux-musleabihf` binary, sha256 `a17e88e6…`, built with rustup-stable + `-C linker=rust-lld` (the Homebrew `rust` toolchain was replaced to unbreak cross-compile). Password on all three P201Mini units is `analog` (PlutoSDR default). Board-1 executed the same M1 smoke with RC=0 on the real dual-A9. Boards 2/3 were physically present and logged in but blocked from parallel execution by an identical-image IP/hostname collision — see [`../docs/SERIAL_NET_FIX.md`](../docs/SERIAL_NET_FIX.md) and `LOCAL_FLASH.md` §0.5/§1.4. Full per-board fact sheet: [`M1_BOARD1_2026-07-04.md`](M1_BOARD1_2026-07-04.md).

### Host run (2026-07-01) — `-sim`
```
$ cargo test
test result: ok. 20 passed; 0 failed
test result: ok. 2 passed; 0 failed   (tests/m1_crypto.rs)

$ cargo run --bin smoke-m1
[M1] X25519 handshake complete: node 1 <-> node 2
[M1] AEAD round-trip OK: 44 bytes plaintext -> 79 bytes on-wire (ChaCha20-Poly1305)
[M1] tamper rejected: flipped tag bit -> Auth error
[M1] replay rejected: re-delivered frame -> Replay error
[M1] PASS (-sim). Re-run on the Zynq Mini ARM node to graduate to hw.
```

## To graduate M1 to `hw`
1. `rustup target add armv7-unknown-linux-gnueabihf`
2. `cargo build --release --target armv7-unknown-linux-gnueabihf`
3. `scp target/armv7-unknown-linux-gnueabihf/release/smoke-m1 mini:/tmp/`
4. On the Mini: `/tmp/smoke-m1` → must print the same PASS lines.
5. Record `uname -a`, throughput/latency of the AEAD loop, and paste the output above.

Prerequisite: the Mini must boot ARM-Linux (tri-net#8) — its FPGA/PS was never
flashed as of 2026-07-01 and is not yet enumerating on USB.
