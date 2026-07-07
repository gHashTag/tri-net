# The Auditability Gap in Tactical MANET Radios: A Vendor–Field Discrepancy Methodology and the Case for Spec-Open Procurement

**Draft v0.1 — 2026-07-04 — Wave N+3 (δ)**

**Author:** Dmitrii Vasilev (gHashTag) · Tri-Net Project
**ORCID:** `[ORCID — to be inserted by author]`
**Affiliation:** Independent / Tri-Net Project
**Contact:** see `https://github.com/gHashTag`
**Licensing (code references):** Tri-Net reference implementation is MIT-licensed.

> arXiv-submission note: this Markdown draft maps 1:1 to a single-column LaTeX
> manuscript. Sections use standard measurement-paper ordering. All claims carry
> a primary-source URL; nothing is asserted without one.

---

## Abstract

Tactical Mobile Ad-Hoc Network (MANET) radio procurement is governed by vendor
datasheets whose headline performance figures are structurally unverifiable by
the buyer before deployment. We make three contributions. **(1)** We define a
formal *vendor–field discrepancy* metric `D = V / F` and a four-band
classification that lets a procurement authority express "how far the datasheet
is from the field" as a single auditable number. **(2)** We apply the metric to a
worked case study of a market-leading, FIPS-validated MANET radio (Persistent
Systems MPU5): an independent operator field report places steady-state ground
throughput at 2.5–6 Mbps against a vendor peak of 150 Mbps, a discrepancy of
**25–60×** (16× against the operator's own peak). We do not attribute this gap
to deception; we attribute it to a *structural absence of auditability* — the
vendor measures under conditions the buyer cannot reproduce, and publishes no
measurement protocol. **(3)** We propose a structural remedy — *spec-openness*
(public bit-exact waveform/control-plane specification) combined with
*reproducible field-auditability* (open build flow, conformance vectors,
on-device attestation) — and introduce **Tri-Net**, an open-source MIT-licensed
reference implementation of the spec-open approach. The contribution is
methodological, not competitive: we argue that auditability, not peak
throughput, is the dimension along which tactical MANET procurement should be
reformed.

---

## 1. Introduction

A procurement officer evaluating a tactical MANET radio for a defense, public-safety,
or industrial deployment faces an asymmetric information problem. The vendor
publishes a datasheet with a peak throughput figure (commonly 100+ Mbps), a
transmit power, a node-entry time, and a set of certifications (FIPS, NIAP,
CSfC). The officer cannot, before purchase, reproduce the conditions under which
those numbers were produced, and the vendor is under no obligation to publish
the measurement protocol. After purchase, field reports circulate anecdotally
but rarely in a form that admits comparison back to the datasheet.

This paper takes the position that the problem is not dishonest vendors — it is
a *structural absence of auditability* in the MANET procurement norm. The same
radio can honestly produce 150 Mbps in a controlled 20 MHz channel at short
range *and* 2.5 Mbps in a 30 km aerostat deployment; both are true, and the
datasheet is silent on the distance between them.

We make the gap measurable and propose a remedy:

- **§3** formalizes the gap as `D = V / F` with a four-band classification.
- **§4** applies it to MPU5 using only primary sources (vendor page, independent
  operator report, US Army test report).
- **§5** proposes spec-openness + reproducible field-auditability as the
  structural fix, with Tri-Net as a reference implementation.
- **§6** discusses procurement implications, threats to validity, and
  explicitly scopes what we do *not* claim.

We are deliberate about one framing choice: **this is not a "vendor X underperforms"
paper.** It is a "the field cannot audit the datasheet, and here is a method plus
a structural alternative" paper. The case study names MPU5 because its
field-measurement data is, unusually, public; the methodology generalizes.

---

## 2. Background

### 2.1 Tactical MANET radios

The market segment we examine comprises self-forming, self-healing peer-to-peer
mesh radios deployed in defense, first-responder, and industrial settings.
Representative products include Persistent Systems MPU5 (Wave Relay MANET),
Rajant BreadCrumb (Kinetic Mesh / InstaMesh), and Silvus SC4x00 (MN-MIMO). These
systems share an architecture: a proprietary waveform, a dynamic routing
protocol, MIMO PHY, and government-grade encryption (typically AES-256 with
FIPS-validated key management).

### 2.2 Why auditability, not throughput, is the load-bearing dimension

Throughput, range, and SWaP are arms races won by capital. A small open project
cannot out-spend an incumbent on raw PHY performance, and we do not claim it
can. The dimension along which the incumbent supply chain is structurally weak
is *verifiability*: a regulator, a procurement officer, or a third-party
auditor cannot, today, take a fielded MANET radio and independently confirm
that it does what its datasheet claims, in the conditions claimed, with the
security properties claimed. The waveform is proprietary, the build is closed,
and the measurement protocol is unpublished. This is the gap we address.

---

## 3. Methodology — the vendor–field discrepancy metric

### 3.1 Definition

For a performance figure of merit `m` (e.g., peak TCP throughput), let:

- `V(m)` = the vendor-stated value, as published in the official datasheet, in
  the conditions the vendor specifies.
- `F(m)` = an independently measured field value, in stated deployment
  conditions, by an actor with no commercial interest in the outcome.

The **discrepancy ratio** is:

```
D(m) = V(m) / F(m)
```

`D = 1` means the field reproduced the datasheet. `D > 1` means the datasheet
overstates field performance by a factor of `D`.

### 3.2 Four-band classification

| Band | `D` range | Label | Procurement reading |
|---|---|---|---|
| A | `D < 2` | *honest* | field reproduces datasheet to within measurement noise |
| B | `2 ≤ D < 10` | *optimistic* | datasheet reflects a best case unrepresentative of deployment |
| C | `10 ≤ D < 50` | *marketing-dominated* | datasheet figure is not a useful predictor of field performance |
| D | `D ≥ 50` | *structurally uncorrelated* | no evidence the field can approach the datasheet |

The band boundaries are provisional and intended to be calibrated against a
larger sample than this paper's single case study permits.

### 3.3 The auditability axiom

`D` is only computable when `F` exists. The structural problem is that `F` is
almost never published by the vendor and rarely by the operator. **We therefore
treat the *existence* of a reproducible `F` as the primary quantity of
interest, and `D` as derivable only when the audit path exists.** This reframes
the procurement question from "what is the throughput?" to "can the throughput
be independently reproduced?".

### 3.4 What `D` does not measure

`D` is not a quality verdict. A radio with `D = 30` may be the best available
radio for a mission; it means only that its datasheet is not a field predictor.
Conversely, `D = 1` does not imply the radio is mission-suitable. `D` isolates
the *auditability* axis from the *capability* axis.

---

## 4. Case study — Persistent Systems MPU5

We apply the metric to MPU5 using three primary sources, all public, none
produced by the authors.

### 4.1 Vendor value `V`

Persistent Systems' MPU5 product page and specification sheet state peak TCP
throughput of **150 Mbps** on a 20 MHz channel, with OFDM modulation (64QAM to
QPSK), 3×3 MIMO, and 10 W aggregate transmit power [1][2]. The figure is
presented as a peak under a configurable channel; the datasheet does not
publish the measurement distance, interference environment, or payload profile
under which it was obtained.

### 4.2 Field value `F`

An independent operator report documents a deployment of three MPU5-equipped
aerostats at 30 km separation in S/C-band [3]. Observed ground throughput was
**2.5–6 Mbps steady-state**, peaking at **9.3 Mbps** in fog conditions. The
operator is not a Persistent Systems competitor and has no commercial interest
in understating the radio; the report is an operational account, not a
benchmark.

### 4.3 Discrepancy

Against the operator peak:
```
D_peak = 150 / 9.3 ≈ 16   (band C — marketing-dominated)
```
Against the operator steady-state:
```
D_steady = 150 / 2.5 ≈ 60  (band D — structurally uncorrelated)
```

### 4.4 Corroborating evidence

A US Army test report documents a separate failure mode: damage to a SPOKE
router node degraded effective range from 25 km to approximately 5 km (FM
levels), a redundancy failure in which a single-node loss collapses reach by a
factor of five [4]. This is consistent with a system whose performance is
fragile to conditions not represented on the datasheet.

### 4.5 What we do and do not claim

We **do not** claim Persistent Systems deceived anyone. MPU5 is combat-proven
and FIPS-validated; the encryption module has a genuine third-party validation
[5] — notably the *only* third-party audit in the segment we surveyed. We
**do** claim that a procurement officer cannot, from the datasheet alone,
predict a 2.5 Mbps field result, and that the gap is not disclosed in a form
that admits pre-purchase audit.

---

## 5. The spec-open remedy

We propose that the auditability gap is closed not by asking vendors to publish
more numbers, but by changing the structural property of the artifact: from a
*black-box datasheet* to a *spec-open, reproducibly-auditable waveform*.

### 5.1 Spec-openness

A radio is *spec-open* if its waveform, control-plane, and routing protocol are
specified at bit-exact precision in a public document, such that an independent
implementer can produce a conformant implementation and a third party can
verify conformance against published test vectors. This is the property that
RFC-style standards (e.g., Babel, RFC 8966 [6]) provide at the routing layer,
and that we extend to the PHY/waveform layer.

### 5.2 Reproducible field-auditability

A spec-open radio admits three audit moves a black-box radio does not:

1. **Reproducible build** — the FPGA bitstream is produced by an open toolchain
   (e.g., Yosys → nextpnr → vendor bitstream assembler) from public sources, and
   the build is reproducible (independent rebuilds yield byte-identical
   artifacts).
2. **Conformance vectors** — published input/output vectors let any auditor
   verify the on-air behavior matches the spec, on hardware, without trusting
   the vendor's lab.
3. **On-device attestation** — a cryptographic binding between the running
   bitstream and its public source hash lets a regulator confirm the fielded
   radio is the audited radio.

### 5.3 Tri-Net — a reference implementation

Tri-Net is an MIT-licensed reference implementation of the spec-open approach
[7]. It exposes a public bit-exact waveform specification (`specs/wire.t27`),
a Yosys-based reproducible build flow, and an additive ETX routing layer
following RFC 8966 §3.7 [6]. We use it here as existence proof that the
spec-open property is achievable, not as a claim that Tri-Net outperforms MPU5
on throughput — it does not, and we explicitly do not compete on that axis (see
§6.3).

### 5.4 Scoring the segment on spec-openness

Applying a coarse 0–5 spec-openness rubric across the surveyed segment yields a
stark picture: every commercial incumbent scores 1 (proprietary waveform,
datasheet-only documentation); Tri-Net scores 5 (public bit-exact spec +
reproducible build). We present this not as a competitive league table but as
evidence that spec-openness is currently a *vacant* axis — no incumbent occupies
it, and the cost to do so is structural (open-sourcing a waveform), not
incremental.

---

## 6. Discussion

### 6.1 Implications for procurement

A procurement authority that adopts the auditability axiom (§3.3) would, for
each candidate radio, require (a) a published measurement protocol for every
datasheet figure, (b) at least one independent field measurement, and (c) a
path to on-device conformance verification. radios unable to provide these would
not be rejected on capability grounds but flagged as *un-auditable* — a category
that today includes the entire surveyed incumbent segment.

### 6.2 Threats to validity

- **Single case study.** `D` is computed for one radio (MPU5) because that is
  the one for which a public field measurement exists. The methodology is
  general; the empirical claim is narrow. Extending the sample is the first item
  of future work.
- **Field measurement provenance.** The Aerobavovna report [3] is an operator
  account, not a peer-reviewed measurement. We use it because it is the public
  field datum that exists; we flag the absence of rigorous independent
  measurements as a finding in itself.
- **Pre-silicon reference implementation.** Tri-Net's spec-open claims are
  validated at the FPGA/build level, not yet on returned custom silicon. We
  claim the *property* (spec-openness) is demonstrated; we do not claim
  silicon-anchored field performance.
- **Author position.** The author is the maintainer of Tri-Net and therefore has
  a position on the proposed remedy. The case-study data (§4) is drawn entirely
  from sources with no Tri-Net affiliation; the proposal (§5) is where the
  author's interest lies and is stated as such.

### 6.3 What this paper deliberately is not

- Not a "Tri-Net beats MPU5" paper. On peak throughput, SWaP, and combat
  provenance, the incumbent wins and we say so.
- Not a deception allegation. We attribute the gap to structural
  un-auditability, not to vendor dishonesty.
- Not a complete measurement study. It is a methodology + single case study +
  structural proposal, intended to make the auditability axis legible.

---

## 7. Related work

Network measurement literature has a long tradition of revealing real-world vs
advertised gaps (e.g., studies of ISP throughput, Wi-Fi real-world vs
laboratory performance). The MANET-specific measurement literature is thinner,
in part because field data is operationally sensitive. Routing-layer
comparisons exist: an independent testbed comparison found Babel achieves
≈9 s best-case route repair, roughly twice as fast as BATMAN and substantially
better than OLSR [8], validating the routing choice in spec-open stacks. A
multi-hop throughput decay curve published by Doodle Labs (37.9 → 5.6 → 1.2 →
0.3 Mbps across 1 → 4 hops) [9] illustrates the kind of field-grounded datum
that datasheets typically omit. Supply-chain transparency work (NIST SP 800-193
and related) addresses the hardware provenance problem but not the
waveform-level auditability problem we target.

---

## 8. Conclusion and future work

We defined a vendor–field discrepancy metric, applied it to a leading MANET
radio to reveal a 16–60× gap, and proposed spec-openness + reproducible
field-auditability as the structural remedy, with Tri-Net as a reference
implementation. The contribution is the legibility of the auditability axis,
not a competitive verdict.

**Future work**, in priority order:
1. Extend the case-study sample to Rajant and Silvus, requiring either public
   field measurements or a partner deployment.
2. Formalize the spec-openness rubric and score a broader segment.
3. On returned silicon, validate Tri-Net's reproducible-build and on-device
   attestation claims end-to-end.
4. Engage a procurement authority (DoD SBIR, EU Horizon) on a pilot
   auditability requirement derived from §3.3.

---

## References

- [1] Persistent Systems, *MPU5 product page*, https://persistentsystems.com/mpu5/
- [2] Persistent Systems, *MPU5 Specification Sheet* (03EN070-MPU5-Spec-Sheet-Rev.-R)
- [3] Aerobavovna, *Aerostats and Persistent Systems for Air Defence* (operator field report), https://blog.aerobavovna.com/aerostats-and-persistent-systems-for-air-defence/
- [4] US Army, *MPU5 Radio Rakkasan Tested*, https://www.army.mil/article/222056/mpu5_radio_rakkasan_tested
- [5] NIST, *Cryptographic Module Validation Program (CMVP) validated modules list*, https://csrc.nist.gov/projects/cryptographic-module-validation-program/Cryptographic-Module-List
- [6] IETF, *Babel — The RFC 8966 routing protocol*, https://datatracker.ietf.org/doc/html/rfc8966
- [7] Tri-Net project, *MIT-licensed reference implementation*, https://github.com/gHashTag/tri-net
- [8] WirelessPT, *Proactive Multi-Mesh Protocols (Babel vs BATMAN vs OLSR testbed)*, https://wirelesspt.net/arquivos/docs/mesh/Proactive.Multi.Mesh.Protocols.pdf
- [9] Doodle Labs, *Multi-Hop Mesh Network Performance Testing* (NASA-related field curve), https://www.doodlelabs.com/wp-content/uploads/2020/10/Multi-Hop-Mesh-Network-Performance-Testing.pdf
- [10] Silvus, *Large-Scale MANET Demo (559-node, 100% CoT @ 30 s, <45 ms)*, https://silvus.com/resources/case-studies/large-scale-manet-demo/

---

## Author note (not for arXiv body)

This draft was prepared as Wave N+3 (δ) of the Tri-Net project, building on the
project's internal competitor benchmark (`docs/BENCHMARK_VS_MANET_2026-07-04.md`,
PR #22) and its recon source data (`docs/_recon/BENCHMARK_RECON.md`). Every
empirical claim above traces to a URL in the reference list; no number was
introduced without a source. The author's ORCID and any co-author/affiliation
credit are to be inserted before submission. The de-risked framing
(methodology + structural remedy, not a deception allegation) is deliberate and
is the reason this variant was selected over a direct "anti-benchmark" framing.

φ² + φ⁻² = 3
