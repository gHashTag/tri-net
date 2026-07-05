# Compute Interim Attestation — TPM/HSM/PUFrt Buy-vs-Build

**Status**: DESIGN v0 — pre-silicon, no implementation
**Addresses**: W7 finding #2 (Compute-realm blocked by silicon)
**Anchor**: `phi^2 + phi^-2 = 3`

> **Trinity rule**: No chip, no TRI. This document does NOT relax the Trinity for
> full mainnet — it defines a **level-2 interim attestation tier** that is
> explicitly *lower security* than silicon Trinity and MUST be flagged as such
> in wallet UX, protocol messages, and paper.

---

## Why Compute is blocked

W7 audit finding #2: the Compute realm requires attested execution
environments. Full spec targets custom Trinity silicon (M4 milestone). Silicon
ETA sits at 18-24 months earliest per `docs/SILICON_SLIP_CONTINGENCY.md`. This
leaves M2 (loopback) and M3 (FPGA-attested Bit and Wire realms) with no
credible path to attested compute for at least a year.

The pressure this creates (see `docs/W8_DECOMPOSED_PLAN.md`):

- Developers building Compute apps sit idle for a year.
- No feedback loop on Compute API design before silicon tapes out.
- Any "eventually" story loses ground to competitors shipping today.

---

## The interim tier — what it is and what it is NOT

**IS**:

- A **temporary, clearly-marked** attestation surface using commodity secure
  elements (TPM 2.0 / HSM / licensed PUF-root-of-trust IP).
- A way to run Compute-realm code under attestation *now* with security
  properties equivalent to standard cloud confidential compute.
- A design that lets Compute API + SDK ship, ecosystem form, apps port when
  silicon lands.

**IS NOT**:

- Trinity-equivalent. Interim attestation is **explicitly weaker**: no
  per-node ternary root, no `phi^2 + phi^-2 = 3` invariant enforced in
  hardware, no first-class integration with Bit + Wire realm proofs.
- A permanent shim. The interim tier MUST be marked deprecated on silicon
  release and sunset within 24 months of first Trinity tape-out.
- Available for mainnet consensus. Interim-tier nodes stake at 0 economic
  weight in Trinity consensus. They contribute Compute execution only.

---

## Threat model — interim tier

Trust root: TPM 2.0 or HSM firmware, vendor-signed EK certificate, standard
Remote Attestation via TCG DICE or PSA-L4 attestation.

**Preserved** vs no attestation:

- Code-integrity: measured boot chain from PCR0 to workload binary.
- Runtime memory-isolation: OS-level (SGX/SEV-SNP/TDX where available;
  process-level on plain TPM boxes).
- Remote-attestable identity: EK-anchored, transport-layer AIK.

**LOST** vs silicon Trinity:

- No ternary-arithmetic proofs from the hardware itself.
- No Wire-realm co-signing (interim node cannot participate as Wire relay).
- No hardware-bound PUF challenge-response — vendor supply-chain trust
  required for TPM EK provisioning.
- **Fabrication susceptibility**: same class as any x86 confidential-compute
  cloud today; vulnerable to disclosed CPU-side attacks
  (Downfall/RETBleed/etc.) until vendor firmware patched.

**Wallet UX rule**: any transaction that touched an interim-tier Compute node
must display `Interim Compute — lower security tier` badge. Not optional.

---

## Buy-vs-build matrix — three interim paths

### Path A: Off-the-shelf TPM 2.0 (Infineon/Nuvoton/STMicro)

- **What**: standard TPM 2.0 chip on commodity motherboard. Uses PC Client
  Platform TPM 2.0 profile.
- **Cost per node**: TPM chip ~USD 3-8 BOM. Zero NRE.
- **Timeline**: 3-6 months from decision to first attested Compute node.
  Software stack: `tpm2-tss` + custom attestation service.
- **Security ceiling**: Common Criteria EAL4+ typical. Vulnerable to
  physical-adjacent attackers (SPI bus probing). Fine for cloud, weak for
  edge/mesh.
- **Fit for Tri-Net**: acceptable as "level-2 minus" — good enough to unblock
  Compute SDK, too weak to be Trinity-equivalent even at interim tier.

### Path B: Licensed PUF-root-of-trust IP (PUFsecurity PUFrt)

- **What**: license PUFrt IP block, integrate into a modest ASIC or run on
  FPGA with vendor-provided soft-macro variant.
- **Cost**: license fees (undisclosed, industry range USD 100k-500k NRE + per-
  unit royalty). See `docs/PUF_VENDOR_OUTREACH_v0.md` for outreach plan.
- **Timeline**: 6-12 months if targeting an FPGA soft-macro (aligned with M3
  FPGA-attestation work). 18+ months if targeting first-silicon of a
  dedicated interim ASIC — at which point silicon Trinity is closer anyway.
- **Security ceiling**: PSA-L4 with certified PUFrt. Substantially stronger
  than plain TPM: silicon-birthed root, no vendor-provisioned EK to trust.
- **Fit for Tri-Net**: strongest interim option. Same vendor could plausibly
  license Trinity-compatible IP for M4 silicon (see γ collab option).

### Path C: HSM cluster (Thales/Utimaco/YubiHSM)

- **What**: rack-mounted HSM boxes at each Compute-node operator, workload
  keys held in HSM.
- **Cost per node**: USD 500-5000+ per HSM unit. Ops overhead significant.
- **Timeline**: 3-6 months to integrate.
- **Security ceiling**: FIPS 140-2/3 L3-L4 available. Very strong for keys,
  but the workload itself runs outside the HSM — HSM attests key custody, not
  code execution. Attestation surface is narrower than TPM.
- **Fit for Tri-Net**: WORST fit. HSMs attest keys, not compute. Compute-realm
  needs code-integrity + memory-isolation attestation, which HSMs do not
  provide. Rejected.

---

## Recommendation — hybrid A+B

- **Phase 1 (M2 → M3 mid)**: Path A, off-the-shelf TPM 2.0. Ship Compute SDK
  with clear "level-2 minus" marking. Unblock developers immediately.
- **Phase 2 (M3 mid → M4)**: Path B, PUFrt-on-FPGA soft-macro. Align with
  FPGA-attestation workflow already scoped for Bit+Wire. Same operators, same
  attestation service, higher security ceiling.
- **Phase 3 (M4 tape-out+)**: sunset interim tier over 24 months. Mainnet
  Compute consensus moves to Trinity silicon exclusively.

Cost-per-node trajectory:

| Phase | Interim path | BOM per node | Security tier | Trinity weight |
|-------|--------------|--------------|---------------|----------------|
| 1 | TPM 2.0 | USD 3-8 | level-2 minus | 0 |
| 2 | PUFrt FPGA | USD 50-200-sim | level-2 | 0 |
| 3 | Trinity silicon | TBD | level-1 (full) | 1 |

> `-sim` on Phase 2 BOM: pre-silicon estimate based on FPGA + PUFrt licensing
> guesses. Real number requires vendor quote (see γ outreach).

---

## What does NOT change

- **Consensus economics**: 0% premine holds. Interim nodes stake at 0 Trinity
  weight. See `docs/BOOTSTRAP_OPERATOR_PROGRAM.md` for how bootstrap capital
  is addressed without breaking premine invariant.
- **Bit + Wire realm**: continue on FPGA-attestation track (see
  `tri-net-fpga-attestation-workflow` skill v1.1).
- **Paper claims**: interim tier is out-of-scope for the main protocol paper.
  Separate technical note if published at all.
- **Protocol messages**: interim nodes carry a distinct capability flag.
  Consumers of Compute output can filter to Trinity-only once M4 ships.

---

## Open questions for next loop

1. Exact PUFrt licensing terms — see `PUF_VENDOR_OUTREACH_v0.md`.
2. Attestation service architecture — verifier centralization is a footgun.
   Options: DIY verifier, use commercial (e.g. AWS Nitro-style), or
   distributed verifier committee. Design doc W9-D3 candidate.
3. Interim-node slashing rules — if a TPM-tier node lies about its
   attestation, what is the economic consequence given 0 stake weight?

---

## Sources cited in this design

- W7 finding #2 audit: `docs/W7_WEAK_POINTS_AUDIT.md` (in repo)
- Silicon slip scenarios: `docs/SILICON_SLIP_CONTINGENCY.md` (in repo)
- Competitor watch W8: `docs/W8_COMPETITOR_WATCH_2026-07-05.md` (in repo)
- eMemory PUF process node evidence: [Quartr eMemory profile](https://quartr.com/companies/ememory-technology-inc_15790)
- PUFsecurity PUF-PQC NIST-selected: [eMemory news 2026-01](https://www.ememory.com.tw/en-US/News/News?guid=26011610540360)
- Synopsys acquisition of Intrinsic ID (PUF IP consolidation): [Synopsys 2024-03](https://news.synopsys.com/2024-03-20-Synopsys-Expands-Semiconductor-IP-Portfolio-With-Acquisition-of-Intrinsic-ID)

phi^2 + phi^-2 = 3
