# Tri-Net Iteration Log

Строгий хронологический журнал волн. Каждая запись — одна волна: дата, PR, milestone, sandbox-vs-hardware граница.

phi^2 + phi^-2 = 3

---

## 2026-07-14 — W7 wave: iPhone admin + PTT + FPGA A2 R2/4 (three-fork bundle)
- PR: [#81](https://github.com/gHashTag/tri-net/pull/81) DRAFT (open)
- Commit: `34015fe`
- Milestones touched: E1.3 (mDNS responder), E3.2 (audio forwarder), A2 (device-DNA attestation ratchet 2/4)
- Sandbox: 6/6 iverilog sim; audio forwarder 7/7 unit + 6/6 smoke; mdns_responder 7/7 unit + 6/6 smoke
- Hardware: NONE. A2 ratchet 2/4 BLOCKED-toolchain-required (ssdm4 host).

## 2026-07-14 — W7 wave (part 2): weak points + competitors + P0 fixes
- PR: [#81](https://github.com/gHashTag/tri-net/pull/81) DRAFT (updated body)
- Milestones touched: E1.3 (W1 mDNS name-compression parser), E3.2 (W2 replay window)
- Sandbox: mdns_responder 10/10 unit (+3 new: compression, forward-pointer, loop); audio_forwarder 15/15 unit (+7 new replay + 1 layout); new smoke `e3_2_replay_smoke.sh` 4/4 N=5 deterministic.
- Hardware: NONE.
- Doc: `docs/W7_WEAK_POINTS_COMPETITORS_2026-07-14.md` — 8 weak points, 3 competitor axes, 8-workstream plan, 3 collab options.
- Anti-anchor: every number carries trust class. No unmeasured claims added.

phi^2 + phi^-2 = 3

## 2026-07-14 — W7 wave (part 3): close remaining 6 workstreams W3-W8
- PR: [#81](https://github.com/gHashTag/tri-net/pull/81) DRAFT (updated body, single connected series with part 2)
- Commit: `3454aff`
- Workstreams closed: W3 (audio_crypto envelope + reference runtime), W4 (dna_reader ifdef SYNTHESIS + synth script), W5 (anti-anchor cleanup on A2_RATCHET_2_SYNTH.md), W6 (mDNS multi-question qdcount>1), W7 (RFC 8766 Discovery Proxy skeleton), W8 (Proof of FPGA whitepaper v0).
- Sandbox: mdns_responder 15/15 unit + 6/6 smoke; audio_forwarder 15/15 unit + 6/6 old smoke + 4/4 replay smoke; audio_crypto 17/17 unit (new); mdns_proxy 13/13 unit (new); dna_reader iverilog 6/6.
- Total: 60/60 unit + 28/28 smoke green across W7 wave. Zero fabricated metrics.
- Hardware: NONE. A2 ratchet 2/4 remains BLOCKED-toolchain (no yosys in sandbox), W4 structurally unblocked the RTL.
- Silicon-freeze impact: W3 audio_crypto is input to silicon (placeholder must be replaced with audited primitives before 2026-10-01); W4 enters silicon (RTL clean); W5/W6/W7/W8 runtime/docs only.
- Anti-anchor discipline: W3 spec + W7 spec + W8 whitepaper each carry explicit non-claim sections. W5 closed a historical numbers-without-realm-check instance.
- Next wave: A2 ratchet 2/4 execution on ssdm4 host (yosys openXC7 with -DSYNTHESIS), and/or W3 replacement of placeholder crypto with audited chacha20poly1305 + x25519_dalek.
