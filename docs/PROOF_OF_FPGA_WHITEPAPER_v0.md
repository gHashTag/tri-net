# Proof of FPGA — a named DePIN primitive

**Whitepaper v0** · draft · 2026-07-14 · Tri-Net Working Group

phi^2 + phi^-2 = 3

---

## Abstract

We introduce **Proof of FPGA** as a named primitive in Decentralised Physical Infrastructure Networks (DePIN). A Proof of FPGA is a cryptographic attestation, produced by a specific field-programmable gate array die, that (a) the die is a specific one from a specific vendor batch (device DNA) and (b) the die is currently running a specific bitstream (bitstream attestation), optionally strengthened by a Physical Unclonable Function (PUF) layer. The construction reuses well-known primitives from the FPGA-security literature ([SACHa DATE 2019](https://ieeexplore.ieee.org/document/8715217), [PUFatt DAC 2014](https://dl.acm.org/doi/10.1145/2593069.2593192), [Guajardo et al. CHES 2007](https://link.springer.com/chapter/10.1007/978-3-540-74735-2_5), [Papalamprou et al. arXiv:2506.21073](https://arxiv.org/abs/2506.21073)); we do not claim novelty in the cryptography. The novelty is the **packaging** of these primitives as a discrete DePIN primitive with a specific revenue model and a specific mesh-integration story.

## 1. Motivation

DePIN networks (Helium, Pollen, World Mobile, Filecoin, Akash, Bittensor) rely on operators contributing physical infrastructure — radios, storage, compute. Payment for that work depends on proving the operator actually did the work. Existing solutions choose one of three anchors:

- **Identity-only** ([Helium Proof-of-Coverage](http://whitepaper.helium.com)): operator has a chip that signs identity messages (ECC608, HIP-19). Chip attests *who* did the work, not *what* was done. Works for coverage. Weak for compute.
- **Software-only** ([Bittensor Yuma Consensus](https://bittensor.com)): operators run a validated model; consensus among validators substitutes for hardware proof. Vulnerable to Sybil at scale and to collusion.
- **Cloud TEE** (AWS Nitro, Intel SGX, ARM TrustZone): trusted execution environments give strong attestation but require trust in the silicon vendor and are unavailable on open FPGA hardware.

Proof of FPGA fills a gap: **strong hardware-anchored attestation on open FPGA hardware**, suitable for compute and coverage workloads that reject cloud-TEE lock-in.

## 2. Threat model

Adversaries we defend against:

- **T1 — Software replay.** Attacker replays a captured attestation from a legitimate device. Defended by nonce/timestamp binding in every attestation.
- **T2 — Bitstream swap.** Attacker programs a modified bitstream (e.g., that fakes work) and expects to still be rewarded. Defended by bitstream-hash attestation (§4.2).
- **T3 — Device impersonation.** Attacker claims another operator's rewards by copying flash contents. Defended by device DNA (§4.1) and, when available, PUF (§4.3).

Adversaries we explicitly do NOT defend against:

- **T4 — Silicon-vendor backdoor.** If the FPGA vendor has hidden test modes that leak DNA or accept spoofed bitstream hashes, Proof of FPGA fails. This is a fundamental limit of any hardware-rooted attestation. Mitigation is vendor diversity (multiple die families in the network).
- **T5 — Physical extraction.** Attacker delaminates the die and reads the DNA and PUF secrets electrophysically. Cost is high; Proof of FPGA raises the bar but does not eliminate this.
- **T6 — Side-channel attacks.** Power analysis of a running attestation could leak PUF challenge responses. Constant-time implementation is out of scope for v0.

## 3. Non-claims

We say these out loud so they cannot be mistaken for our claims:

- We do NOT invent PUF. See [Guajardo et al. CHES 2007](https://link.springer.com/chapter/10.1007/978-3-540-74735-2_5) for the SRAM-startup PUF construction, and [PUFatt DAC 2014](https://dl.acm.org/doi/10.1145/2593069.2593192) for processor-based PUFs.
- We do NOT invent bitstream attestation. See [SACHa DATE 2019](https://ieeexplore.ieee.org/document/8715217) for the strongest primitive we build on: an FPGA proving to a verifier that a specific bitstream is loaded without a trusted third party.
- We do NOT invent PQC-signed FPGA attestations. See [Papalamprou et al. arXiv:2506.21073](https://arxiv.org/abs/2506.21073) for a recent construction that binds signatures to blockchain.
- We do NOT claim FPGA proof replaces silicon-level attestation for all threat models. It complements silicon and is open-hardware-friendly.

## 4. Construction

### 4.1 Device DNA (A2 stage)

Every 7-series Xilinx die exposes a 57-bit device DNA via the `DNA_PORT` primitive ([UG768 §Device DNA](https://docs.amd.com/v/u/en-US/ug768_7Series_XADC_XilinxWiki), [XAPP1082](https://docs.amd.com/v/u/en-US/xapp1082-secure-boot)). UltraScale dies use a 96-bit DNA via `DNA_PORTE2`. Equivalent primitives exist on Efinix (Trion), Lattice (ECP5), Achronix.

Our A2 implementation lives in `fpga/attest/dna_reader.v`. On reset the module pulses `READ`, then shifts 57 bits out on `DOUT` MSB-first, and latches the value in `dna_out` guarded by a `valid` strobe. Simulation goes through iverilog + a behavioural stand-in (`sim/dna_port_model.v`); synthesis goes through openXC7 + yosys `synth_xilinx -family xc7` (with a `(* blackbox *)` DNA_PORT stub gated by the `SYNTHESIS` define, W4).

**Attestation payload for A2**: `H(nonce ‖ device_dna)` signed by a hardware-anchored key derived from device_dna (§4.4). Verifier holds the public key of the operator; a MITM cannot replay one device's response as another because `device_dna` differs.

### 4.2 Bitstream attestation (A3 stage)

We hash the loaded bitstream with SHA-3 and sign the hash with the A2 key. The verifier holds the "golden hash" of the sanctioned bitstream and checks: (a) the signature verifies under the operator's public key, (b) the hash matches the golden hash, (c) the nonce is fresh.

The primitive is [SACHa (DATE 2019)](https://ieeexplore.ieee.org/document/8715217). Our contribution is not the primitive — it is the integration path: the same signing key that A2 uses, the same nonce discipline, and delivery over the mesh transport (see §5).

**Gate for A3**: swap in a modified bitstream, verifier must reject. Original bitstream verifies. Replay of yesterday's attestation is rejected (nonce/timestamp binding).

### 4.3 PUF layer (A4 stage)

A PUF (Physical Unclonable Function) uses manufacturing variations in the die — e.g., which SRAM cells power up to 0 vs 1, or which of two ring-oscillators is faster — to derive a per-die secret that cannot be reproduced by cloning. On 7-series and UltraScale we use SRAM-startup PUF ([Guajardo et al. CHES 2007](https://link.springer.com/chapter/10.1007/978-3-540-74735-2_5)); on families without accessible startup SRAM we use ring-oscillator PUFs.

Target metrics (all `-sim` until measured on real silicon per the A1-A4 ratchet):

- Intra-device Hamming distance < 5% (stable across temperature and voltage).
- Inter-device Hamming distance > 45% (near-ideal 50%).

The PUF response is folded into the A2 key derivation (§4.4) so that an attacker who extracts flash and key store still cannot reproduce the identity without the die itself.

### 4.4 Key derivation

```
identity_key = KDF(device_dna ‖ puf_response ‖ die_family_id)
```

where KDF is any accepted key derivation function (HKDF-SHA-256 in the v0 reference). The identity key is used to sign both A2 and A3 attestations. The KDF binding to `die_family_id` is a defence-in-depth measure against cross-family key confusion.

## 5. Mesh integration

Attestations are transported over the Tri-Net mesh (`trios_meshd`) inside the same envelope that carries other overlay traffic. For confidentiality and integrity, we wrap the attestation in the crypto envelope specified in `specs/audio_crypto.t27` (W3, 2026-07-14 — currently uses `-crypto-placeholder` primitives; audited replacement pending). This gives:

- **Confidentiality**: passive observers cannot correlate attestations to physical devices.
- **Integrity**: bit-flips in transit are rejected by the MAC.
- **Replay resistance**: nonce freshness enforced by the envelope's counter.

## 6. Monetization

Concrete revenue paths, cited in `tri-net-fpga-attestation-workflow` skill §Monetization Vectors:

1. **DePIN hardware proof as a service** — SDK that lets other DePIN projects plug in "this attested FPGA ran this workload". Per-verification metering or per-node license.
2. **TEE-alternative for mesh routing** — sold to sovereignty-focused telecom, defence-adjacent civilian, high-assurance IoT — buyers who reject Intel SGX / ARM TrustZone lock-in.
3. **Audit-as-a-service** — periodic attestation sweeps of a customer's deployed fleet: "prove no board has been swapped or reflashed since deployment".
4. **Tri-Net internal use** — every node ships with Proof of FPGA baked in; premium tier for enterprise / defence buyers.
5. **Standards / consortium play** — anchor a DePIN attestation standard; revenue from certification services.

## 7. Ratchet discipline

Every Proof of FPGA claim must survive the four-stage ratchet documented in `tri-net-fpga-attestation-workflow` skill:

1. **Sim (Verilator / cocotb)** — all edge cases pass in code.
2. **Synth (Vivado / Efinix / Lattice)** — place-and-route completes without timing violations.
3. **Single-device smoke** — device DNA reads, PUF stable across ≥10 power cycles, bitstream hash signs and verifies.
4. **Cross-device smoke** — attestations from board-A rejected as replay on board-B.

Skip any stage — the primitive is `-sim` until the missing stage passes. This mirrors the discipline of `tri-net-m2-m4-workflow` §Sandbox-vs-hardware.

Silicon-freeze date for Tri-Net's SKY26b tape-out is **2026-10-01** (78 days from this document). Any primitive not through A1–A4 by that date ships FPGA-only until the next silicon spin.

## 8. Current status (honest snapshot, 2026-07-14)

- **A1 Literature survey**: DONE. `docs/W7_FPGA_LITERATURE.md`.
- **A2 Device-DNA read**: RTL exists, iverilog ratchet 1/4 GREEN 6/6. Ratchet 2/4 (yosys openXC7) blocked-toolchain in this sandbox; W4 in W7 part-3 fixed the RTL structure so the synth path is unblocked on any host with yosys. Ratchets 3/4 and 4/4 pending hardware access.
- **A3 Bitstream attestation**: not started. Planned as A3 workstream in a future wave.
- **A4 PUF layer**: not started.
- **A5 Whitepaper**: THIS DOCUMENT (v0).

Nothing in §4-§5 has been measured on a Tri-Net node in the field. All metrics in this document are structural or cited — no fabricated numbers.

## 9. What v0 does not cover

- Formal security proofs of the KDF binding.
- Constant-time implementation guidance.
- Hardware-specific side-channel mitigation.
- Comparative benchmarks vs Intel SGX / AWS Nitro (requires the SKY26b tape-out to be back from fab).
- Cross-family attestation composition (e.g., a Tri-Net node with both a Zynq-7020 and an Efinix Trion on the same PCB).

These land in whitepaper v1 after A2–A4 ratchets are GREEN on hardware.

## 10. References

Inline citations above use full URLs. Consolidated bibliography:

- Guajardo, J., Kumar, S. S., Schrijen, G.-J., & Tuyls, P. (2007). FPGA Intrinsic PUFs and Their Use for IP Protection. *CHES 2007*. [Springer link](https://link.springer.com/chapter/10.1007/978-3-540-74735-2_5).
- Aysu, A., Ghalaty, N. F., Franklin, Z., Yali, M. P., & Schaumont, P. (2014). PUFatt: Embedded Platform Attestation Based on Novel Processor-Based PUFs. *DAC 2014*. [ACM link](https://dl.acm.org/doi/10.1145/2593069.2593192).
- Zeitouni, S., Vliegen, J., Frassetto, T., Koch, D., Sadeghi, A.-R., & Mentens, N. (2019). SACHa: Self-Attestation of Configurable Hardware. *DATE 2019*. [IEEE link](https://ieeexplore.ieee.org/document/8715217).
- Papalamprou, P., et al. (2025). Post-Quantum-Secure FPGA Attestations Anchored on Blockchain. arXiv:2506.21073. [arXiv link](https://arxiv.org/abs/2506.21073).
- Helium. Proof-of-Coverage. [Whitepaper](http://whitepaper.helium.com).

phi^2 + phi^-2 = 3
