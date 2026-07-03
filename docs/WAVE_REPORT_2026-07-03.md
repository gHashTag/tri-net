# Tri-Net · Wave Loop Report — 2026-07-03

**Agent:** Perplexity Computer (cloud sandbox) · **Duration:** 4 × 15 min waves
**Repo state read:** `main` @ `116fa97` (`feat(t27): port wire.rs -> specs/wire.t27`)
**Anchor:** φ² + φ⁻² = 3

> **Honesty preface.** This report was produced from a cloud sandbox with read
> access to the GitHub repo, not from a local Claude Code loop on your Mac.
> Previous chat log claims about "120 tests / 68 T27 modules / FPGA validation
> project ready / ZedBoard procurement" are **not verified against this
> repository** — the tree actually contains 1 T27 spec, ~22 unit + 2 integration
> Rust tests, and a P201/P203 Mini + AX7203 target (not ZedBoard). We work from
> the real code.

---

## 1 · Reality snapshot

| Layer | Real status | Location |
|---|---|---|
| M1 crypto (X25519 + ChaCha20-Poly1305 + ratchet + zeroize) | ✅ host-tested and armv7l on-device on P201Mini | `src/crypto.rs`, `smoke/M1_RESULTS.md` |
| M2 routing (ETX/WMEWMA, hop-by-hop AEAD, TTL) | 🟡 host-tested, in open PR stack #11–#17 | `src/routing.rs`, `src/router.rs`, `src/daemon.rs` |
| M2 bin (`trios-meshd` over UDP as radio stand-in) | 🟡 works, HELLO=300 ms, force_dead after 2 misses | `src/bin/trios_meshd.rs` |
| PHY (BPSK + RRC/timing/CFO host model, GF16 OFDM sim) | 🟡 `-sim` only, never touched AD9361 | `src/modem.rs`, `src/gf16.rs` |
| T27 port | 🟡 wire only (1 spec, 8 tests) | `specs/wire.t27` |
| Zynq-7020 Mini FPGA/PS | 🔴 never flashed | tri-net#8 |
| RF (external PA/LNA/directional antenna) | 🔴 greenfield | tri-net#9, `-hw` |

---

## 2 · Weak-spots heatmap (found this wave)

| # | Weak spot | Severity | File(s) | Wave-N fix |
|---|---|---|---|---|
| W1 | Handshake = Noise-NN (unauthenticated ephemeral DH) → MITM/Sybil indistinguishable | **CRIT** | `src/crypto.rs` | E1 · Noise-XX |
| W2 | Plaintext HELLO — no MAC, no freshness — attacker forges `heard[]` to become `best_next_hop` (classic AODV false-metric) | **CRIT** | `src/discovery.rs`, `src/router.rs` | E2 · authenticated HELLO |
| W3 | `handle_frame` does not verify `header.src == transport-peer link.peer` — a linked neighbor can spoof `src=someone_else` | **CRIT** | `src/router.rs` | E3 · src cross-check |
| W4 | `best_next_hop()` ranks only direct neighbors — no multi-hop additive path ETX, no loop-avoidance, no Babel feasibility | HIGH | `src/routing.rs` | E4 · Babel path metric |
| W5 | Only one next-hop; backup path is recomputed on the fly, no cached disjoint alternative | HIGH | `src/routing.rs`, `src/router.rs` | E5 · `ranked_next_hops(k=2)` |
| W6 | Self-heal convergence threshold **UNDEFINED** — the M5 demo has no PASS/FAIL number | HIGH | `docs/ROADMAP.md`, daemon | E6 · <5 s link / <10 s node |
| W7 | `ETX_WINDOW=3` + `FAST_FAIL_MISSES=2` at `HELLO_MS=300` — double-decision path: WMEWMA decay vs force_dead miss counter can fire in opposite direction and thrash | MED | `src/bin/trios_meshd.rs` | tune + calibration test |
| W8 | `handle_frame` looks up session **by claimed src** before validating identity → cheap DoS via arbitrary-src spam | MED | `src/router.rs`, `src/daemon.rs` | E7 · rate-limit |
| W9 | Fixed 64-frame replay window, on lossy multi-hop with ~50% half-duplex will false-reject reordered frames | MED | `src/crypto.rs` | E8 · parametrized WIDTH |
| W10 | GF16 has JSON vectors but no SHA-256 anchor / no 0x47C0 conformance / no sim↔hardware parity check | LOW | `tests/gf16_conformance.rs` | E10 · 84-format anchor |
| W11 | `/tmp/mesh.drop` in demo daemon is world-writable — any local process can kill any link (demo-only, unsafe on field node) | LOW | `src/bin/trios_meshd.rs` | privilege gate |

---

## 3 · Science → prescriptions

| Weak spot | Prescription | Primary reference |
|---|---|---|
| W1 | Noise-XX (mutual auth) over the existing X25519 + ChaCha20-Poly1305 primitives | [Noise Protocol Framework](https://noiseprotocol.org/noise.pdf) · [libp2p Noise spec](https://github.com/libp2p/specs/tree/master/noise) |
| W2 | SAODV — MAC non-mutable fields, hash-chain TTL, seq+timestamp freshness | [Zapata & Asokan, WiSe 2002, IEEE 5376147](https://ieeexplore.ieee.org/document/5376147) |
| W4 | Babel — additive path metric + feasibility condition | [RFC 8966](https://datatracker.ietf.org/doc/html/rfc8966) |
| W5 | LB-OPAR — node-disjoint path balancing, +30% flow success, +4× throughput | [Sharma et al., arXiv:2205.07126](https://arxiv.org/abs/2205.07126) |
| W6 | Threshold-based failover >95% link congestion, sub-second detect | [Fraunhofer IIS FANET architecture, UASFeed 2026](https://uasfeed.com/article/swarm-mesh-networking-explained) · [BFD RFC 5880](https://datatracker.ietf.org/doc/html/rfc5880) |
| ETX@mobility | WMEWMA α-tuning for UAV cruise speeds, PARRoT LET | [Rosati et al., arXiv:1307.6350](https://arxiv.org/abs/1307.6350) · [Sliwa et al. PARRoT, arXiv:2012.05490](https://arxiv.org/abs/2012.05490) |
| ETX+ML | AODV+SDN+ML ETX weight optimisation → +32.7% throughput / −40.2% delay | [Journal of Applied Informatics and Computing 2026](https://jurnal.polibatam.ac.id/index.php/JAIC/article/view/12737) |
| W8 | Sybil / false-metric mitigations | [arXiv:1407.3987](https://arxiv.org/abs/1407.3987) |
| W9 | libsodium parametrized replay + heavy-reorder tests | [libsodium docs](https://libsodium.gitbook.io/) |
| Cortex-A9 CT | ChaCha20-Poly1305 embedded audit | [DATE 2017, doi:10.23919/DATE.2017.7927118](https://ieeexplore.ieee.org/document/7927118) |
| W10 | 84-format catalogue + 0x47C0 anchor cross-checked with `ml_dtypes` | [arXiv:2606.09686](https://arxiv.org/abs/2606.09686) |

---

## 4 · Decomposed plan (Sprint 1 → 4)

### Sprint 1 — Identity & message integrity (this week, all `auto=true`)

| ID | Task | Files | Acceptance | Est |
|---|---|---|---|---|
| E1.1 | Add `noise-protocol` (or hand-rolled XX) crate, wire XX pattern | `src/crypto.rs` (+ `noise` module) | XX handshake completes in unit test | 4h |
| E1.2 | Bind NodeId ↔ static-key allow-list | `src/crypto.rs`, `src/bin/trios_meshd.rs` | Wrong static key → `MeshError::Auth` | 2h |
| E1.3 | Property test: NN attempt refused when XX mode | `tests/m1_crypto.rs` | 100/100 refused | 1h |
| E1.4 | Fuzz test XX rejection on mismatched keys | `tests/` | fuzz corpus green | 1h |
| E2.1 | Add `ts:u64`, `mac:[u8;16]` to `Hello` wire format (bump `VERSION` if breaks) | `src/discovery.rs`, `src/wire.rs` | Existing tests updated | 3h |
| E2.2 | MAC via ChaCha20-Poly1305 over `(src,seq,ts,heard[])` under session key | `src/discovery.rs` | Tampered `heard[]` fails MAC | 2h |
| E2.3 | Freshness gate: reject if `\|now - ts\| > 2*HELLO_MS` | `src/bin/trios_meshd.rs` | Old beacon dropped | 1h |
| E2.4 | Attack sim: forged `heard[]` cannot raise ETX >5% | `tests/attack_false_metric.rs` (new) | passes | 2h |
| E3.1 | In `router.rs::handle_frame`, compare `hdr.src` to `from` (link peer) | `src/router.rs` | mismatch → `Dropped(SrcSpoof)` | 30m |
| E3.2 | Add `DropReason::SrcSpoof` variant | `src/router.rs` | enum exhaustive | 15m |
| E3.3 | Test A→C with `header.src=B` → dropped | `src/router.rs` (test) | 100% drop | 30m |

### Sprint 2 — Path diversity & self-heal gate

| ID | Task | Acceptance |
|---|---|---|
| E4 | Multi-hop Babel path ETX with feasibility condition (RFC 8966 §3.7) | 100 random topology fuzz → 0 loops |
| E5 | `ranked_next_hops(k=2)` node-disjoint, hot-swap on `force_dead` | Failover latency <300 ms measured (bench) |
| E6 | Instrument `link_loss_to_reroute_ms` + `node_off_to_reroute_ms`, emit JSON | CI gate: <5 s link, <10 s node |

### Sprint 3 — Hardening

| ID | Task | Acceptance |
|---|---|---|
| E7 | Rate-limit + bounded neighbor table (LRU cap N=32) | 10 k/s spam does not grow table >32 |
| E8 | Parametrized replay WIDTH ∈ {64, 128, 256} + heavy-reorder test | 50% reorder + 20% loss → no false Replay |
| E9 | Constant-time CI audit (`dudect` or `cargo-crev` + manual review) | No secret-dependent branches on Cortex-A9 |

### Sprint 4 — Verification parity

| ID | Task | Acceptance |
|---|---|---|
| E10 | 84-format golden vectors + 0x47C0 anchor as CI gate | Bit-exact GF16 output sim vs future Verilog |
| E11 | GF16 sim vs `iverilog+vvp` cross-check on ported `specs/gf16_ofdm.t27` | 100% vector match |

---

## 5 · Three cooperation lanes for the **next Wave loop**

Each lane is *self-contained* and *unblocking* — start any (or all in parallel).

### 🅰 Lane A — Security hardening (fast, high-signal, all Rust auto=true)
**Scope:** E1 · E2 · E3 (Sprint 1)
**Actor fit:** cryptography-comfortable Rust dev, no hardware
**Deliverable:** 3 PRs (Noise-XX, authenticated HELLO, src cross-check), each with attack-sim test that turns red without the fix, green with it
**DEMO artefact:** `cargo test --test attack_false_metric` — MITM/forgery blocked
**Cite:** noiseprotocol.org · IEEE 5376147 (SAODV) · arXiv:1407.3987
**Effort:** ~2 dev-days · **Risk:** LOW (isolated code paths, unit-testable)

### 🅱 Lane B — Path diversity + self-heal gate (measurable DEMO GATE)
**Scope:** E4 · E5 · E6 (Sprint 2)
**Actor fit:** routing-protocol dev + one field-test operator
**Deliverable:** Babel path ETX, ranked next-hops, instrumented convergence — plus a **numeric PASS/FAIL** for M5 (<5 s link, <10 s node), matching Fraunhofer's threshold-based failover pattern
**DEMO artefact:** 3-node UDP triangle on a laptop, `mesh.drop` induces failure, `link_loss_to_reroute_ms` JSON on stdout shows <5000 ms
**Cite:** RFC 8966 (Babel) · arXiv:2205.07126 (LB-OPAR) · UASFeed FANET failover
**Effort:** ~3–4 dev-days · **Risk:** MED (invariant-heavy, needs topology fuzz)

### 🅲 Lane C — Verification-parity + T27 datapath port (bridges to FPGA)
**Scope:** E10 · E11 · continued T27 porting (`etx.t27`, `gf16_ofdm.t27` after `wire.t27`)
**Actor fit:** dev comfortable with `iverilog+vvp`, integer DSP, and CI plumbing
**Deliverable:** 84-format SHA-256 golden vectors as CI gate + `iverilog+vvp` cross-check on ported T27 → **sim==silicon** guarantee before flashing
**DEMO artefact:** CI job `t27-vvp-parity` that fails if Rust GF16 diverges from Verilog output by even 1 LSB
**Cite:** arXiv:2606.09686 (84-format catalogue) · arXiv:2606.05017 (GF16)
**Effort:** ~3 dev-days for E10/E11; T27 port is ongoing (2–4h/module)
**Risk:** LOW-MED (mostly plumbing; unlocks FPGA path when hardware issue #8 lands)

---

## 6 · Boundary — what this wave *cannot* do

- Cannot flash Zynq-7020 Mini (tri-net#8) — needs Vivado + physical cable
- Cannot procure PA/LNA/antennas (tri-net#9) — needs a human with a budget
- Cannot run 5.8 GHz OTA in Thailand — regulatory; keep the UDP transport for dev
- Cannot merge PRs — merge stack in `docs/MERGE_ORDER.md` is human-only per repo policy

Everything in Sprints 1–4 above is `auto=true` and can be executed by a local
loop today with the existing `docs/AUTONOMOUS.md` protocol (one focused, tested
PR per iteration; never push to `main`).
