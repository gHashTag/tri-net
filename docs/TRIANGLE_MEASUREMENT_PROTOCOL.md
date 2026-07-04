# Tri-Net Triangle Measurement Protocol (L0–L4)

**Status:** public reproducibility spec — v0.1, 2026-07-04
**Owner:** Tri-Net project (MIT-licensed reference implementation)
**Purpose:** define, in advance and in public, exactly how Tri-Net measures its own
MANET radio performance on real hardware, so that every number we publish is
reproducible by a third party. This document is the operational expression of the
auditability axiom argued in [`docs/WAVE_N3_AUDITABILITY_GAP_2026-07-04.md`](WAVE_N3_AUDITABILITY_GAP_2026-07-04.md)
(δ paper): *the existence of a reproducible measurement protocol is the primary
quantity — not the throughput number.*

This is the artifact we ask incumbent vendors to produce and do not. We produce
it for ourselves first.

---

## 1. Hardware under test

| Role | Board | SoC | RF PHY | Boot | Source of truth |
|---|---|---|---|---|---|
| Node | Puzhi **P201Mini** ×3 | Xynq-7020 (xc7z020, 2× Cortex-A9 @ 667 MHz) | AD9361 transceiver (70 MHz–6 GHz, 2×2 MIMO) | ARM-Linux on PS | [`radio/README.md`](../radio/README.md), [`smoke/M1_RESULTS.md`](../smoke/M1_RESULTS.md) |

**Already verified on one node (2026-07-01):**
- AD9361 IQ datapath at 5.8 GHz: internal digital loopback, 1 MHz tone recovered at +0.999 MHz, **108.6 dB over noise floor**.
- M1 crypto on-device: X25519 handshake + ChaCha20-Poly1305 AEAD + tamper/replay rejection, **RC=0** on the dual-Cortex-A9 (`smoke-m1`, static `armv7-...-musleabihf`, sha256 `e5abc335…7290a`).

**Open hardware prerequisites (block specific levels, not the protocol):**
- PL/FPGA bitstream is **not yet flashed** as of 2026-07-01 ([`smoke/M1_RESULTS.md`](../smoke/M1_RESULTS.md) footnote) — PS-only operation until then.
- No on-board OFDM PHY yet ([`radio/README.md`](../radio/README.md), "Next — greenfield").
- RF loopback (L2) needs SMA cable + attenuator; OTA (L3/L4) needs antennas + legal-low-power config.

These gaps are recorded here deliberately. A protocol that hides its
prerequisites is not reproducible.

---

## 2. Access model

```bash
ssh root@<mini>          # hostname pzp201mini for node 1; <mini> is a placeholder
```
- Each node runs ARM-Linux on the PS and exposes AD9361 via `/sys/bus/iio/`.
- Measurements run **on-node**; analysis (FFT, stats) runs **on the host** after pulling captures.
- One node's hostname is `pzp201mini`; nodes 2 and 3 get recorded in §3 capture files as they come online.

---

## 3. Honesty policy (applies to every level)

Every published number carries a tag from this closed set:

| Tag | Meaning |
|---|---|
| `hw` | measured on the real P201Mini, protocol followed exactly |
| `sim` | measured in simulation only |
| `openwifi-baseline` | measured via the `openwifi` reference PHY on our hardware — **not our modem** |
| `raw-IQ-ceiling` | capacity of the raw AD9361 sample pipe, **not application throughput** |
| `?` | not yet measured; the protocol exists, the datapoint does not |

A number without a tag is a defect in this document, not a result. We never
publish a datasheet-style peak without the tag that qualifies it.

---

## 4. Level 0 — Sanity on three nodes (foundation)

**Goal:** prove all three nodes reach the same baseline that node 1 reached on 2026-07-01.

### Per node
```bash
ssh root@<mini> 'sh ad9361_loopback.sh'                 # -> /tmp/rx.dat on node
ssh root@<mini> 'cat /tmp/rx.dat' > rx_nodeN.dat        # pull to host
python3 analyze_tone.py rx_nodeN.dat 30720000           # -> peak + SNR
ssh root@<mini> '/tmp/smoke-m1; echo RC=$?'             # M1 on-device
```
(`ad9361_loopback.sh` env knobs: `LO TONE N LOOPBACK`; see [`radio/README.md`](../radio/README.md).)

### Record (per node) into `smoke/TRIANGLE_SANITY.md`
- `uname -a`, `iio:device0` name (must be `ad9361`)
- AD9361 loopback: FFT peak frequency, SNR-over-noise-floor (dB)
- `smoke-m1` RC (must be 0)
- binary sha256 (must match `e5abc335…7290a` or a newly-recorded rebuild hash)

### Pass criterion
All three nodes: peak within ±10 Hz of the tone, SNR ≥ 100 dB (digital loopback), RC=0. **No inter-node comparison to MPU5 yet** — this is foundation only.

### Executable now?
**No.** Requires nodes powered and on the network. As of this writing `pzp201mini`
is not resolvable from the development host. L0 is the first thing to run when the
nodes are back online; it is not blocked by any code gap.

---

## 5. Level 1 — M1 crypto microbench on Cortex-A9 (radio-independent)

**Goal:** the first column we can populate honestly and that no incumbent
publishes — pure PS crypto throughput/latency on the flying node's ARM cores.

### Add `bin/microbench-m1`
A tiny binary that loops the AEAD encrypt/decrypt and the X25519 handshake and
prints wall-clock throughput/latency over a fixed payload size (e.g. 64 B, 1500 B).
Cross-built `armv7-...-musleabihf`, same toolchain as `smoke-m1`.

### Per node, record into `smoke/M1_MICROBENCH.md`
| Metric | Payload | Value | Tag |
|---|---|---|---|
| ChaCha20-Poly1305 AEAD throughput | 1500 B | X Mbps | `hw` |
| ChaCha20-Poly1305 AEAD throughput | 64 B | Y Mbps | `hw` |
| X25519 handshake latency | — | Z µs | `hw` |
| Replay-window check cost | — | W ns | `hw` |

### Why this matters for the benchmark
This is the first cell where Tri-Net's column can drop the `-sim` tag while MPU5's
and Rajant's stay `?` (unpublished). Per the δ paper, **the existence of the
reproducible number is the win**, regardless of its magnitude.

### Executable now?
Code (`bin/microbench-m1`) can be written now; **running it requires node access**
(same blocker as L0).

---

## 6. Level 2 — RF loopback over SMA + attenuator (transmitter validation)

**Goal:** validate the actual RF front-end (not just the digital path) and produce
numbers comparable to Silvus/Doodle Labs EVM data.

### Setup
`LOOPBACK=2` on one node: TX → SMA cable → attenuator → RX of the same node.

### Record into `smoke/L2_RF_LOOPBACK.md`
- TX EVM at 5.8 GHz
- TX spectrum mask (regulatory cleanliness)
- RX sensitivity floor (dBm)

### Honesty tag
`hw`. Comparable to vendor EVM figures where vendors publish them.

### Executable now?
**No.** Needs SMA cable + attenuator physically connected. Protocol-only until the
RF bench is assembled.

---

## 7. Level 3 — Two-node OTA link (the honesty fork)

**Goal:** first over-the-air datapoints. **Critical caveat:** Tri-Net has no
in-house OFDM PHY yet ([`radio/README.md`](../radio/README.md)). Two honest options:

- **(a) `openwifi-baseline`** — run the `openwifi` reference 802.11 PHY on our
  AD9361 and measure PER-vs-distance and throughput. This is *openwifi on our
  hardware*, not Tri-Net's modem. Tagged `openwifi-baseline`.
- **(b) `raw-IQ-ceiling`** — measure the raw AD9361 IQ sample pipe throughput with
  no modem. This is a *capacity ceiling*, not application throughput. Tagged
  `raw-IQ-ceiling`.

**The protocol publishes BOTH columns**, never one masquerading as the other. The
δ paper's thesis is that this dual-column honesty is itself the contribution.

### Setup
Two nodes, low power (≤100 mW, AD9361 internal PA 10–15 dBm, no external PA yet),
directional antennas if available.

### Record into `smoke/L3_OTA.md`
| Distance | PER (openwifi-baseline) | PER (raw-IQ-ceiling) | Tag |
|---|---|---|---|
| 1 m | ? | ? | `?` |
| 3 m | ? | ? | `?` |
| 10 m | ? | ? | `?` |

### Executable now?
**No.** Needs two nodes online + antennas + legal-low-power verification. May need
`openwifi` integration work first.

---

## 8. Level 4 — Three-node triangle + self-heal (M4/M5 demo gate)

**Goal:** the main-event number for a follow-up paper — **convergence time under
our own Babel-lite routing**, directly comparable to MPU5 (Rakkasan range
collapse) and Silvus (559-node demo).

### Setup
Triangle of three P201Mini. One uplink: Ethernet → mesh → the other two.

### Record into `smoke/L4_TRIANGLE.md`
- **Convergence time** on `force_dead` of one node (link-level and node-level) —
  uses the E6 instrumentation from PR #23. CI gates: <5 s link, <10 s node.
- **iperf3 end-to-end** across 2 hops.
- **Self-heal routing replay** (Sprint 2 `force_dead` → ranked next-hop hot-swap).

### Honesty tag
`hw` once measured. This is the cell that converts the δ paper's M3 row from
`target` to `measured`.

### Executable now?
**No.** Needs three nodes online + networking configured. Depends on L0 passing
first.

---

## 9. Output schema — what each level populates

The protocol exists to feed two downstream artifacts, tagged:

- **`docs/BENCHMARK_VS_MANET_2026-07-04.md`** — a new column
  `Tri-Net (P201Mini hw)` appears as each level completes. L1 fills the crypto
  row; L2 fills EVM; L4 fills M3 self-heal (the cell that currently reads
  `target <5 s link`).
- **Follow-up paper** *"Auditability Validated: Tri-Net Self-Measurement on
  P201Mini"* — Tri-Net becomes the first honest case study in its own `D`-scale,
  with `D ≈ 1` where the protocol is public and `D = ?` where measurement is
  pending. Even the absence of a number is data, provided the protocol is public.

---

## 10. Executability matrix (honest, current)

| Level | Code ready? | Hardware ready? | Runnable this session? |
|---|---|---|---|
| L0 sanity ×3 | ✅ (scripts exist) | ⛔ nodes offline | **No** — needs nodes on network |
| L1 M1 microbench | ⛔ `bin/microbench-m1` to write | ⛔ nodes offline | **No** — code + nodes |
| L2 RF loopback | ✅ (`LOOPBACK=2`) | ⛔ SMA+atten bench | **No** — RF bench |
| L3 OTA | ⛔ openwifi/raw-IQ | ⛔ antennas+2 nodes | **No** |
| L4 triangle | ✅ (E6 in PR #23) | ⛔ 3 nodes + net | **No** |

**Nothing is runnable this session because no node is reachable.** The protocol's
value today is that it exists publicly and defines exactly what runs the moment
hardware comes back — which is the property the δ paper demands of vendors and
which we therefore demand of ourselves.

---

## 11. Reproducibility checklist (for a third party)

To reproduce any level, a third party needs:
1. Three P201Mini (or any Zynq-7020 + AD9361 board booting ARM-Linux).
2. This repository at the tagged commit.
3. The level's script (`ad9361_loopback.sh`, `smoke-m1`, future `microbench-m1`).
4. The capture/analysis tool (`analyze_tone.py`).
5. This protocol document.

If any of these is missing or opaque, the result is not reproducible and must not
be tagged `hw`.

---

## 12. What this protocol deliberately does not do

- Does not promise a throughput number. It promises a **method**.
- Does not compete with MPU5 on peak Mbps. It competes on **auditability**.
- Does not hide prerequisites. Every blocker is a named row in §10.
- Does not publish a number without a tag from §3.

---

φ² + φ⁻² = 3

The protocol is the product. The numbers follow when the hardware does.
