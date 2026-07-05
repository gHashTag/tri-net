# Regulatory status — 5.8 GHz mesh, single source of truth

> phi^2 + phi^-2 = 3

**Purpose**: consolidate everything the project knows about legal ability to run
5.8 GHz over-the-air (OTA) mesh experiments. Previously scattered across three
docs; consolidated per W7 finding #6.

**Date of this snapshot**: 2026-07-05, measured on main @ `13e4692`.

**Do not** treat this document as legal advice. It is a status board for
internal go/no-go decisions. Actual OTA experiments require a licensed operator
and, in most jurisdictions, written authorization filed with the regulator.

---

## Status table

| Jurisdiction | 5.8 GHz OTA status for mesh | Power ceiling (unlicensed) | Path to licensed test | Next-step date | Source |
|---|---|---|---|---|---|
| Thailand (Phuket, primary dev location) | **CLOSED** for mesh use without NBTC license | 100 mW EIRP under Wi-Fi-like rules; mesh routing not covered | Requires NBTC individual radio license; no application filed | n.a. — blocked | [docs/WAVE_REPORT_2026-07-03.md:145](https://github.com/gHashTag/tri-net/blob/main/docs/WAVE_REPORT_2026-07-03.md) |
| Singapore | Similar to TH — licensed-by-rule 100 mW ceiling for point-to-point | 100 mW | IMDA test license process (~4-8 weeks) | not initiated | [docs/STRENGTHEN.md P8 BVLOS row](https://github.com/gHashTag/tri-net/blob/main/docs/STRENGTHEN.md) |
| UAE (ADGM / DIFC via Hub71+) | **OPEN** in principle via ADGM / DIFC RegLab sandbox | Case-by-case per sandbox admission | Hub71+ AI Cohort 20 application (deadline 2026-08-02) is prerequisite step | 2026-08-02 (application deadline) | [README.md:169](https://github.com/gHashTag/tri-net/blob/main/README.md); [docs/LOCAL_FLASH.md:413](https://github.com/gHashTag/tri-net/blob/main/docs/LOCAL_FLASH.md) |
| USA (FCC, hypothetical) | 5.725-5.850 GHz U-NII-3 unlicensed; mesh permitted with 802.11 rules | 1 W conducted / 4 W EIRP with cert | Would require FCC Part 15 subpart E cert for radio module | not on roadmap | n.a. — not the target market |
| EU (CEPT, hypothetical) | 5.725-5.875 GHz ISM; mesh permitted with SRD rules | 25-500 mW depending on band segment | ETSI EN 300 440 / EN 302 502 conformance | not on roadmap | n.a. — not the target market |

## What can be done RIGHT NOW (no license, no OTA)

1. **Digital loopback**: AD9361 internal TX→RX digital path. Already done, SNR 108.6 dB (`radio/README.md:7-14`). Note: this is **not an over-the-air measurement**, see [W7 finding #5](W7_WEAK_POINTS_STRUCTURAL.md#находка-5).

2. **SMA RF loopback with attenuator**: TX SMA → attenuator → RX SMA, contained inside the lab. No radiation. Listed as "next (still greenfield)" in [`radio/README.md:26-29`](https://github.com/gHashTag/tri-net/blob/main/radio/README.md); the physically-next legal experiment. Planned in [`docs/LOCAL_FLASH.md §9.3`](https://github.com/gHashTag/tri-net/blob/main/docs/LOCAL_FLASH.md).

3. **UDP transport dev** (current): mesh routing logic (`trios_meshd`) runs on loopback UDP without touching the radio front-end. This is what M2 gate v2 tests. Legal everywhere.

## What is BLOCKED until further notice

- **Any 5.8 GHz radiated experiment in Thailand**. No route to legal until NBTC license or Hub71+ ADGM sandbox admission.
- **Field flight tests with mesh in the air**. Requires both spectrum authorization AND drone flight authorization (separate BVLOS process; see `docs/STRENGTHEN.md` P8 row).
- **Public claims of "5.8 GHz mesh works"** based on digital loopback numbers. See W7 finding #5.

## Contingency chain

If Hub71+ 2026-08-02 application is **not** admitted:
- Fallback A: apply to IMDA (Singapore) sandbox — precedent for DePIN radio experiments exists.
- Fallback B: partnership with an existing licensed operator (defense contractor, university) — no candidate identified as of 2026-07-05.
- Fallback C: keep radio arm at digital + SMA loopback, ship remaining stack (T27 codegen, FPGA attestation, token protocol) which do not require spectrum.

## Cross-references

- Finding [W7 #6](W7_WEAK_POINTS_STRUCTURAL.md#находка-6) — this file addresses that finding.
- [`docs/LOCAL_FLASH.md`](LOCAL_FLASH.md) — hardware handling procedures.
- [`docs/BENCHMARK_VS_MANET_2026-07-04.md`](BENCHMARK_VS_MANET_2026-07-04.md) — regulatory row in the boundary table.
- [`README.md`](../README.md) — hardware matrix; this document should be linked next to the matrix.

---

phi^2 + phi^-2 = 3
