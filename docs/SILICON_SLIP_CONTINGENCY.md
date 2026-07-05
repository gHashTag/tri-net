# Silicon slip contingency — three scenarios

> phi^2 + phi^-2 = 3

**Purpose**: address [W7 finding #1](W7_WEAK_POINTS_STRUCTURAL.md#находка-1). The
project's compute-arm and public roadmap both hang on a single date — TT SKY26b
Trinity tape-out 2026-12-16 ([`README.md:26,167`](../README.md)). Between
tape-out and returned silicon there is typically 8-16 weeks. This document
enumerates three explicit slip scenarios and the arms that continue in each.

**Snapshot**: 2026-07-05, main @ `13e4692`.

**Silicon-anchor score reference**: see [`docs/BENCHMARK_VS_MANET_2026-07-04.md`](BENCHMARK_VS_MANET_2026-07-04.md) §M7. Level 5 = "custom ASIC returned + on-chain verifier". Level 3 = "FPGA bitstream anchor + signed measurement". Level 2 = "TPM/secure-element attestation".

---

## Scenario 1 — Slip 3 months (tape-out 2027-03-16, returned silicon ~2027-07)

**Assumption**: fab schedule slips one quarter (foundry congestion, mask revision, or minor DRC issue).

**Compute arm**: remains at **level 2** (TPM/HSM attestation as interim, per finding #2 mitigation) or **level 3** (FPGA bitstream anchor via Track B / Proof-of-FPGA arm) through 2027-07.

**Transport / Coverage / Sensor arms**: unaffected. Continue to operate software-signed per [`README.md:67-70`](../README.md).

**Token emission**: Era 0 rewards continue for Transport/Coverage/Sensor at software-signed level. Compute-arm rewards paused OR paid at reduced multiplier tied to attestation level. Explicit rule: **no Compute-arm reward > Transport reward until level 4+ attestation available**.

**Public communication**: silicon-anchor score in README updates to `level 3 (FPGA + signed)` with dated note "level 5 target pushed to 2027 Q3". No headline claim revision needed.

**Trigger for scenario 2 escalation**: if by 2027-05-01 no returned silicon confirmed, invoke scenario 2.

---

## Scenario 2 — Slip 6 months (tape-out 2027-06-16, returned silicon ~2027-10)

**Assumption**: major mask revision, or fab schedule + one bug-fix cycle.

**All of scenario 1** plus:

**Compute arm design change**: publish an amended whitepaper section explicitly moving Compute-arm sybil resistance to "level 3 FPGA-bitstream anchor + PUF measurement" as the **operating** baseline, with level 5 as future upgrade. This aligns with the [`M2_M4_FPGA_DECOMPOSED_PLAN.md`](M2_M4_FPGA_DECOMPOSED_PLAN.md) Track B monetization vectors (FPGA-attestation-as-a-Service).

**Economic**: extend Era 0 emission curve or introduce a slower halving in Era 0 to compensate for delayed Compute-arm activation. Requires token governance decision by 2027-04-01.

**Risk to Trinity narrative**: rename to "Trinity FPGA + Trinity ASIC (future)" everywhere in public materials. Do not drop the ASIC track; but reduce marketing weight until returned silicon is on the table.

**Trigger for scenario 3 escalation**: if by 2027-09-01 no returned silicon confirmed, invoke scenario 3.

---

## Scenario 3 — Slip 12+ months (tape-out 2027-12+, returned silicon 2028+ or indefinite)

**Assumption**: fundamental redesign, fab loss, funding constraint on tape-out.

**Options** (must pick one by 2027-09-01):

**3A — pure FPGA network**: promote Proof-of-FPGA (Track B) from parallel arm to primary. Silicon-anchor score at level 3, permanent until further notice. Whitepaper amended. The advantage: real product, real hardware, real sybil resistance. Loss: no longer a "silicon-anchor DePIN", positioning shift required.

**3B — partner with existing PUF vendor**: license Intrinsic ID (Synopsys since 2024) SRAM-PUF IP OR PUFsecurity IP, integrate into an off-the-shelf SoC (RISC-V), skip in-house Trinity ASIC entirely. Silicon-anchor score reaches level 4 via partner-attested chip. Loss: dependence on external IP vendor; economic model needs adjustment for royalty flow.

**3C — kill Compute arm cleanly**: publicly retire Compute-arm from the whitepaper. Continue as three-arm DePIN (Transport/Coverage/Sensor). Loss: half the whitepaper structure gone; refund/burn any pre-committed reserves earmarked for Compute-arm. Preserve project integrity by clean deprecation rather than indefinite promise.

**In all three 3-options**: token supply / halving schedule remains unchanged. What changes is which arm can claim proof-of-work.

---

## What is decided vs deferred

**Decided now** (documented in this file):
- Slip 3 months → continue on FPGA-anchor without whitepaper change (scenario 1)
- Slip 6 months → whitepaper amendment moving compute baseline to FPGA (scenario 2)
- Trigger dates: 2027-05-01 (scenario 2 check), 2027-09-01 (scenario 3 check)

**Deferred** (requires governance / community vote when triggered):
- Choice between 3A / 3B / 3C
- Economic curve adjustment specifics for scenario 2

## Cross-references

- [W7 finding #1](W7_WEAK_POINTS_STRUCTURAL.md#находка-1) — this file addresses that finding.
- [`docs/BENCHMARK_VS_MANET_2026-07-04.md`](BENCHMARK_VS_MANET_2026-07-04.md) §M7 — silicon-anchor score definition.
- [`docs/M2_M4_FPGA_DECOMPOSED_PLAN.md`](M2_M4_FPGA_DECOMPOSED_PLAN.md) — Track B (FPGA-attestation) is the operational backup in scenarios 1 and 2.
- [`README.md:26,167`](../README.md) — tape-out date and roadmap.

---

phi^2 + phi^-2 = 3
