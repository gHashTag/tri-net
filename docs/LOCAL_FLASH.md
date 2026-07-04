# LOCAL_FLASH — P201Mini bring-up & M1×3 graduation procedure

**Status:** public procedure — v0.1, 2026-07-04
**Purpose:** the exact, repeatable steps to take each of the three P201Mini nodes
from "ARM-Linux booted" through (a) M1 crypto graduation on-device and
(b) AD9361 5.8 GHz digital-loopback sanity. This is the operational sibling of
[`docs/TRIANGLE_MEASUREMENT_PROTOCOL.md`](TRIANGLE_MEASUREMENT_PROTOCOL.md) level
L0. It exists so that M1×3 is a mechanical operation, not an improvisation.

Everything below is derived from the already-verified 2026-07-01 single-board
results in [`smoke/M1_RESULTS.md`](../smoke/M1_RESULTS.md) and
[`radio/README.md`](../radio/README.md). Nothing here is new science — it is the
existing one-board procedure, parameterized for three.

---

## 0. Prerequisites

| Need | Status | Source |
|---|---|---|
| P201Mini boots ARM-Linux on PS (tri-net#8) | ✅ verified 2026-07-01 (one board) | `smoke/M1_RESULTS.md` |
| SSH `root@<mini>` works (key or password) | ✅ was working 2026-07-01 | — |
| `iio_info` / `/sys/bus/iio/devices/*/name = ad9361` present on node | ✅ | M1 run log |
| Host cross-build toolchain (`armv7-unknown-linux-musleabihf`) | ✅ rustup + bundled rust-lld | `smoke/M1_RESULTS.md` |
| **PL/FPGA bitstream flashed** | ⛔ **NOT flashed as of 2026-07-01** | `smoke/M1_RESULTS.md` footnote |

The unflashed PL does not block M1 (crypto runs on the PS Cortex-A9) and does not
block AD9361 digital loopback (loopback is on-chip, no PL needed). It **does**
block any PL-side modem work (M2 radio Transport and beyond) — flagged here so
nobody mistakes M1 graduation for "the FPGA is ready."

---

## 1. Host toolchain (once, on the dev Mac)

```bash
rustup target add armv7-unknown-linux-musleabihf
cargo build --release --target armv7-unknown-linux-musleabihf --bin smoke-m1
# verify the static binary:
file target/armv7-unknown-linux-musleabihf/release/smoke-m1
sha256sum target/armv7-unknown-linux-musleabihf/release/smoke-m1
```
The reference 2026-07-01 binary was 534 604 B, sha256 `e5abc335…7290a`,
`armv7-...-musleabihf`, `-C target-feature=+crt-static`. A rebuilt binary need not
match that hash byte-for-byte (toolchain drift), but **record its own sha256** —
that hash is the provenance stamp for the run.

---

## 2. Per-node procedure (repeat for each of the three nodes)

Substitute `<mini>` with the node's hostname or IP. Node 1's reference hostname is
`pzp201mini`; nodes 2 and 3 are recorded in §3 as they come online.

### 2a. M1 crypto on-device
```bash
scp target/armv7-unknown-linux-musleabihf/release/smoke-m1 root@<mini>:/tmp/smoke-m1
ssh root@<mini> '/tmp/smoke-m1; echo RC=$?'
```
Expected output (from 2026-07-01):
```
[M1] X25519 handshake complete: node 1 <-> node 2
[M1] AEAD round-trip OK: 44 bytes plaintext -> 79 bytes on-wire (ChaCha20-Poly1305)
[M1] tamper rejected: flipped tag bit -> Auth error
[M1] replay rejected: re-delivered frame -> Replay error
RC=0
```
**Pass:** `RC=0` and all four lines present.

### 2b. Node identity + AD9361 presence
```bash
ssh root@<mini> 'uname -a; echo "---"; cat /etc/hostname; echo "---"
                 grep -l ad9361 /sys/bus/iio/devices/*/name 2>/dev/null'
```
Record: `uname -a`, hostname, that an `iio:deviceN name = ad9361` exists.

### 2c. AD9361 5.8 GHz digital loopback
```bash
# on the node:
ssh root@<mini> 'sh ad9361_loopback.sh'                  # -> /tmp/rx.dat
# pull + analyze on host:
ssh root@<mini> 'cat /tmp/rx.dat' > rx_nodeN.dat
python3 analyze_tone.py rx_nodeN.dat 30720000            # -> peak + SNR
```
(`ad9361_loopback.sh` env: `LO TONE N LOOPBACK`; `LOOPBACK=1` = digital, the
verified path. See [`radio/README.md`](../radio/README.md).)
**Pass:** FFT peak within ±10 Hz of the tone, SNR ≥ 100 dB over noise floor.

---

## 3. M1×3 graduation matrix — append to `smoke/M1_RESULTS.md`

Add one row per node:

| Date | Node | hostname / IP | `uname -m` | `iio:device` | `smoke-m1` RC | binary sha256 | loopback peak | SNR (dB) | Status |
|---|---|---|---|---|---|---|---|---|---|
| 2026-07-01 | node 1 | `pzp201mini` | armv7l | ad9361 | 0 | `e5abc335…7290a` | +0.999 MHz | 108.6 | ✅ `hw` |
| _pending_ | node 2 | _TBD_ | | | | | | | `?` |
| _pending_ | node 3 | _TBD_ | | | | | | | `?` |

**M1×3 is closed** when all three rows show `RC=0`, a recorded sha256, peak within
tolerance, and SNR ≥ 100 dB. Until then the milestone column stays `hw (1/3)`.

---

## 4. Output file: `smoke/TRIANGLE_SANITY.md`

Once §3 has three green rows, generate `smoke/TRIANGLE_SANITY.md` (the L0 capture
file referenced by the measurement protocol) with: per-node `uname -a`,
hostname/IP, `iio:device0` name, loopback peak + SNR, `smoke-m1` RC, binary
sha256, and a one-line "all three baselines identical within tolerance" verdict.

---

## 5. Known limits & honesty tags

- M1×3 graduation is **PS-only**. It proves the crypto core runs on each node's
  Cortex-A9. It says nothing about RF range, mesh routing, or PL modem — those
  are M2+ and blocked by the unflashed FPGA.
- AD9361 digital loopback (`LOOPBACK=1`) is on-chip; it proves the transceiver
  tunes and the IQ pipe breathes, **not** that anything is radiated. RF loopback
  (`LOOPBACK=2`, SMA + attenuator) is L2 in the measurement protocol and a
  separate procedure.
- Every number recorded carries the `hw` tag from
  [`TRIANGLE_MEASUREMENT_PROTOCOL.md`](TRIANGLE_MEASUREMENT_PROTOCOL.md) §3.

---

## 6. Executability (current session)

**Not runnable now.** No node is reachable from the dev host this session
(`pzp201mini` does not resolve; the known-hosts IP `64.247.201.38` refuses SSH on
all recorded ports). M1×3 runs the moment a node is powered and on the network —
there is no code gap, only a hardware-availability gap.

---

φ² + φ⁻² = 3

M1×3 = the one-board 2026-07-01 procedure, three times, recorded.
