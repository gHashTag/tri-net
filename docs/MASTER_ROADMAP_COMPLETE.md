# tri-net Complete Roadmap: W12 → W25

**Anchor:** phi^2 + phi^-2 = 3
**Updated:** 2026-07-07

---

## Wave Index

| Wave | Phase | Name | Status | Specs Added |
|------|-------|------|--------|-------------|
| W12 | Hardware | Board recovery + M1 crypto | DONE | 0 (existing) |
| W13 | Mesh | Convergence + Channel T specs | SPECS DONE | +4 |
| W14 | Product | Chat UX + deployment | SPECS DONE | +1 |
| W15 | PHY | Photo (Channel P) | SPECS DONE | +2 |
| W16 | PHY | Video (Channel V) | SPECS DONE | +1 (planned) |
| W17 | FPGA | BPSK modem in Verilog | PLANNED | +1 (planned) |
| W18 | FPGA | AES-256-GCM in PL | PLANNED | +1 (planned) |
| W19 | FPGA | OFDM FFT-256 in PL | PLANNED | +1 (planned) |
| W20 | Integration | 3-channel demo | PLANNED | +1 (planned) |
| W21 | Field | Outdoor range test | PLANNED | 0 |
| W22 | Security | Hardening + audit | PLANNED | +1 (planned) |
| W23 | Production | Persistent rootfs bake | PLANNED | 0 |
| W24 | Demo | Partner video + docs | PLANNED | 0 |
| W25 | Release | Open source v1.0 | PLANNED | 0 |

**Current: 80 specs. Target: ~85 specs at W20.**

---

## Milestone Mapping

| Milestone | Wave | Gate |
|-----------|------|------|
| M1 crypto | W12 | X25519+AEAD on ARM ✅ |
| M2 mesh | W13 | ETX convergence, 2+ boards |
| M3 iperf | W15 | 2-hop throughput test |
| M4 uplink | W20 | Shared gateway, 3-node triangle |
| M5 self-heal | W22 | Re-route on link failure < 5s |

---

## Critical Path

```
W12 (boards) → W13 (mesh) → W14 (UX) → W20 (integration)
                                         ↑
W15 (photo) → W16 (video) ───────────────┘
                                         ↑
W17 (FPGA BPSK) → W18 (FPGA AES) → W19 (FPGA OFDM) ─┘
```

W17-W19 can run in parallel with W15-W16 (different workstreams).

---

## Resource Summary

| Resource | Used | Available |
|----------|------|-----------|
| Specs (.t27) | 80 | ~85 target |
| Generated (.rs) | 80 | auto |
| Rust tools | 5 | as needed |
| P201Mini boards | 3 | 3 |
| AD9361 | 3 | 3 |
| FPGA LUT free | ~35k | 53.2k total |
| FPGA DSP free | ~208 | 220 total |
| FPGA BRAM free | ~75 | 140 total |

phi^2 + phi^-2 = 3
