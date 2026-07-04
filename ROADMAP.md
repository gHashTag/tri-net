# tri-net — Roadmap

**TRI-NET drone-mesh + DePIN node** — "Starlink без спутников" плюс Helium-style
DePIN на одной P203 Mini. Часть Trinity Project. Anchor: **φ² + φ⁻² = 3**.

> Naming: drone-mesh internet-delivery + DePIN экономический слой поверх.
> Отличать от ternary-computing "TRI-NET" silicon-node трека.

## Honest status (2026-07-04, report v3.0)

Все неверифицированные метрики — `-sim`. On-device evidence — под `smoke/` и `radio/`.

| Layer | State | Evidence |
|---|---|---|
| M1 crypto on ARM (X25519 + ChaCha20-Poly1305) | **hw** ✅ | `smoke/M1_RESULTS.md` 2026-07-01, armv7l, RC=0 |
| AD9361 5.8 GHz digital loopback | **hw** ✅ | `radio/README.md` 2026-07-01, SNR 108.6 dB |
| Three P203 Mini boards connected | **hw** ✅ | User confirmation 2026-07-04 |
| M2 TUN/IP + ETX | `-sim` | Rust tests only |
| M3 iperf3 2 hops | `-sim` | not run |
| M4 3-node triangle shared uplink | `-sim` | P2 DEMO GATE, not run |
| M5 self-heal convergence | undefined | B11 unlanded |
| DePIN four-arm proofs (Transport/Compute/Coverage/Sensor) | `-sim` (mock) | see `docs/LOCAL_FLASH.md#5` |
| trinity-contracts on Base L2 mainnet | not deployed | Sepolia only |
| TT SKY26b silicon 1 GOPS @ 50 MHz @ 1 W | projected | tape-out 2026-12-16 |
| Energy multiplier ×4-8 (95% CI [3, 10]) | projected | `[Open conjecture]` |

## Boards
| Board | Chip | Role |
|---|---|---|
| ALINX AX7203 | Artix-7 `xc7a200t` (IDCODE `0x13636093`) | bench compute + video-radio + 2×GbE mesh (proven silicon) |
| **P201/P203 Mini** × 3 | Zynq-7020 `xc7z020` + AD9361 SDR + GPS/PPS | flying MVP DePIN node — M1 crypto `hw`, AD9361 PHY `hw` |

## Roadmap

- **P0 — bring-up** ✅ done — toolchain, first flash, Mini boots ARM-Linux, AD9361 up.
- **P1 — radio + M1 → M3** in progress — AD9361 5.8 GHz PHY `hw`, M1 crypto `hw`,
  ждёт M2 TUN/ETX и M3 iperf3.
- **P1.5 — LOCAL_FLASH triad** in progress (2026-07 window) — три `P203 Mini` до
  Success Gate по `docs/LOCAL_FLASH.md` (три RC=0, три AD9361 loopback runs,
  6/6 X25519 handshakes, три mock-DePIN proofs).
- **P2 — DEMO GATE (3-node triangle)** target 2026-08 — M4 shared uplink over
  3-node mesh + M5 self-healing convergence measured + первый двойной demo:
  mesh-transport-proof + coverage-proof одновременно живые. Deliverable: video
  + metrics + Apache-2.0 + Zenodo DOI.
- **P2.5 — Hub71+ AI Cohort 20** deadline 2026-08-02 — подача через
  `gHashTag/golden-chain-international` (UAE ADGM/DIFC).
- **P3 — video-radio + drone C2 (MAVLink)** — один радиоканал несёт mesh +
  телеметрию + видео.
- **P4 — tethered drone (Flying-COW analog)** — постоянно висящий узел.
- **P5 — free swarm** — self-organizing swarm, каждый узел = DePIN operator.
- **P6 — Trinity silicon back** — tape-out 2026-12-16 → returned silicon →
  BitNet-ternary benchmark on die → закрытие `[Open conjecture]` compute-anchor'а.
- **P7 — Genesis Day** — mainnet deploy `trinity-contracts` на Base L2,
  `EmissionController.renounceOwnership()`, первый public proof-of-inference за TRI.
- **P8 — VAK papers acceptance** — публикация arXiv:2606.05017 (GoldenFloat) и
  каталога 84-format в К-1 журналах перечня ВАК (см. `gHashTag/trinity-papers-ru`).

## Related repos
- [`gHashTag/trinity-contracts`](https://github.com/gHashTag/trinity-contracts) — Base L2 (TRI, MiningPool 7 checks, EmissionController 9 halvings, ChipRegistry PUF).
- [`gHashTag/trinity-node`](https://github.com/gHashTag/trinity-node) — DePIN daemon.
- [`gHashTag/trinity-sdk`](https://github.com/gHashTag/trinity-sdk) — Python API.
- [`gHashTag/trinity-papers-ru`](https://github.com/gHashTag/trinity-papers-ru) — ВАК-трек.
- [`gHashTag/golden-chain-international`](https://github.com/gHashTag/golden-chain-international) — UAE international edition.
- [`gHashTag/t27`](https://github.com/gHashTag/t27), `gHashTag/tt-trinity-{phi,euler,gamma}`, `gHashTag/paper3-methodology`.

See [`drone-mesh`](https://github.com/gHashTag/tri-net/issues?q=is%3Aissue+label%3Adrone-mesh) issues (EPIC + children).
