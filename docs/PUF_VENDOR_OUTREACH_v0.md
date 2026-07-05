# PUF Vendor Outreach v0 — PUFsecurity + eMemory Cold Package

**Status**: OUTREACH DRAFT v0 — no messages sent, package for review
**Addresses**: γ collab option from W8 wave report; supports W9-D1 Compute
interim path B (PUFrt licensing) and long-term M4 Trinity silicon path
**Anchor**: `phi^2 + phi^-2 = 3`

> This document is a **draft package**, not an executed campaign. Nothing
> sent. Nothing committed. Terms below are **questions to ask**, not offers
> to make.

---

## Why these two vendors

**eMemory Technology** — Taiwan-listed IP licensor. Non-volatile memory +
security IP. NeoPUF and NeoFuse products. Advanced-node process support
including Intel 18A cohort. Reported PUF-line revenue growth +607% YoY in
recent disclosure ([Quartr eMemory profile](https://quartr.com/companies/ememory-technology-inc_15790)).
Publicly-listed → structured licensing motion, transparent counterparty.

**PUFsecurity** — eMemory subsidiary focused on productized PUF-root-of-trust
IP (PUFrt). PUF-PQC (post-quantum crypto binding) selected by NIST-track
processes per company disclosure ([eMemory news 2026-01](https://www.ememory.com.tw/en-US/News/News?guid=26011610540360)).
PUFrt targets PSA-L4 attestation stacks — direct fit for `docs/COMPUTE_INTERIM_ATTESTATION.md`
path B.

Why not others:

- **Synopsys / Intrinsic ID**: consolidated into Synopsys 2024 per
  [Synopsys 2024-03](https://news.synopsys.com/2024-03-20-Synopsys-Expands-Semiconductor-IP-Portfolio-With-Acquisition-of-Intrinsic-ID).
  Enterprise sales motion, high floor for licensing engagement, likely
  mismatched with a pre-launch DePIN project. Consider only if
  eMemory/PUFsecurity path stalls.
- **Verayo**: defunct per [PitchBook profile](https://pitchbook.com/profiles/company/55111-87).
  Skip.

---

## Outreach constraints

- **Draft only.** No messages sent from this document. Any actual outreach
  requires an explicit "отправляй" from the general.
- **No fabricated status.** Tri-Net is pre-silicon, pre-mainnet. Do not
  describe it as anything else.
- **No premature revenue promises.** Any per-node royalty framing must be
  presented as a design question, not a commitment.
- **Anchor discipline.** `phi^2 + phi^-2 = 3` in outreach material as
  signature/anchor.

---

## Cold email draft — PUFsecurity

**Subject**: Tri-Net — PUFrt licensing enquiry for pre-silicon DePIN
attestation stack

Hello PUFsecurity team,

I am writing on behalf of Tri-Net, a pre-mainnet DePIN protocol whose
attestation model requires hardware-anchored roots of trust across three
realms (Bit / Wire / Compute). We are currently designing the Compute-realm
interim attestation tier ahead of our own Trinity silicon, and PUFrt is on
our short list of viable IP blocks.

Three questions we would like to work through with your team:

1. **Licensing model for pre-launch DePIN projects.** PUFrt licensing is
   typically structured for OEMs shipping consumer/industrial devices. Is
   there a licensing model — NRE-only, evaluation-license, or something
   staged — that fits a pre-mainnet protocol integrating on FPGA soft-macros
   during a bring-up window, then transitioning to ASIC over 12-24 months?

2. **Per-node royalty structure for DePIN operator networks.** In a DePIN
   context, "shipments" are node operators (independently owned devices
   attesting to a decentralized protocol). Do you have prior structures for
   royalty per attested-node, or do you prefer volume-based tape-out royalty
   as usual? We can share our attestation flow if helpful.

3. **PSA-L4 stack compatibility.** Our wire format is defined in Rust with a
   T27 ternary encoding. We would like to understand whether your reference
   PSA-L4 stacks are agnostic to workload cryptography choices, or whether
   there are constraints (curve selection, PQC transitions from
   [your PQC PUF announcement](https://www.ememory.com.tw/en-US/News/News?guid=26011610540360))
   that would drive our upper-layer design.

Happy to sign an NDA and share our attestation-flow design docs if there is
mutual interest. No commercial commitment intended at this stage — this is a
technical scoping conversation.

Regards,

[Signatory placeholder — do not fill without general approval]
Tri-Net Protocol
Anchor: phi^2 + phi^-2 = 3

---

## Cold email draft — eMemory Technology (IR / BD)

**Subject**: Tri-Net — NeoPUF / NeoFuse enquiry via subsidiary PUFsecurity

Hello eMemory team,

We have separately reached out to PUFsecurity regarding PUFrt licensing for
our pre-mainnet DePIN protocol Tri-Net. Copying you for awareness given the
IP relationship and because two questions sit at eMemory rather than
subsidiary level:

1. **Process-node roadmap.** Public disclosure indicates NeoPUF / NeoFuse
   qualification on advanced nodes including recent 18A cohort ([Quartr eMemory profile](https://quartr.com/companies/ememory-technology-inc_15790)).
   For a small-batch Trinity ASIC targeted 12-24 months from now, which
   process nodes would you recommend given our expected volume tier?

2. **Multi-year IP partnership model.** For a protocol that will start on
   FPGA soft-macros of PUFrt and later spin dedicated Trinity silicon
   integrating PUF as first-class root-of-trust, does eMemory + PUFsecurity
   offer a coordinated licensing path across both phases, or are they
   separate contracts?

We understand this is not a typical inbound. Happy to provide technical
detail on our attestation model under NDA.

Regards,

[Signatory placeholder]
Tri-Net Protocol
Anchor: phi^2 + phi^-2 = 3

---

## Reference-page package (attachments if requested)

Documents to make available under NDA to responsive counterparties:

1. `docs/COMPUTE_INTERIM_ATTESTATION.md` — this workflow's Compute interim
   tier design, path B is where PUFrt lands.
2. `docs/PAPER_DELTA_v0.md` — public paper delta, technical framing of
   Trinity attestation goals.
3. `docs/REGULATORY_STATUS.md` — jurisdictional posture (TH/SG/UAE/US/EU),
   avoids surprising counterparty compliance review.
4. `docs/W8_COMPETITOR_WATCH_2026-07-05.md` — competitor landscape, shows we
   are aware of eMemory revenue trajectory and Synopsys/Intrinsic ID
   consolidation.
5. FPGA-attestation workflow spec (skill `tri-net-fpga-attestation-workflow`
   v1.1) — describes how PUFrt-on-FPGA soft-macro would slot into our M3
   architecture.

Do NOT attach:

- Anything about token economics, emissions, or Era-0 multipliers. Vendor
  outreach is a hardware conversation, not a token conversation.
- Internal audit files (`W8_WEAK_POINTS_AUDIT.md`,
  `SILICON_SLIP_CONTINGENCY.md`). These are candid internal risk framings and
  do not belong in an early vendor conversation.

---

## Follow-up cadence (if a reply arrives)

1. **First reply** — acknowledge within 24h, propose 30-min discovery call.
2. **Discovery call** — technical scoping only. No commercial commitments.
   General must be on the call or explicitly delegate.
3. **NDA** — vendor's paper is usually acceptable; if not, use standard
   mutual NDA. Legal review required before signing.
4. **Technical deep-dive** — share reference-page package (numbered above),
   run 60-90 min workshop on attestation flow + wire format.
5. **Commercial term-sheet** — ONLY after both sides confirm technical fit.
   Draft returns to `docs/PUF_VENDOR_TERMSHEET.md` (W10+ candidate),
   confirm_action required before signing.

---

## Success criteria for γ this loop

γ is deliberately low-cost: the goal is **package prepared, ready to send**,
NOT sent. Signals of success:

- Two draft emails exist, reviewable by general.
- Reference-page attachment list decided.
- Contact-target list identified (BD / IR contact endpoints must still be
  looked up by hand or via warm intro; not part of this document).
- Follow-up cadence defined so response handling is not improvised.

Failure modes to avoid:

- Sending mail without general's explicit approval.
- Fabricating any status claim about Tri-Net's maturity.
- Making commercial offers in the first message.
- Attaching internal risk documents to a cold outreach.

---

## Sources cited in this outreach package

- eMemory PUF revenue trajectory + process-node evidence: [Quartr eMemory profile](https://quartr.com/companies/ememory-technology-inc_15790)
- PUFsecurity PUF-PQC NIST-selected: [eMemory news 2026-01](https://www.ememory.com.tw/en-US/News/News?guid=26011610540360)
- Synopsys/Intrinsic ID consolidation: [Synopsys 2024-03](https://news.synopsys.com/2024-03-20-Synopsys-Expands-Semiconductor-IP-Portfolio-With-Acquisition-of-Intrinsic-ID)
- Verayo defunct: [PitchBook profile](https://pitchbook.com/profiles/company/55111-87)

phi^2 + phi^-2 = 3
