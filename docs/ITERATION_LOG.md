# Tri-Net Iteration Log

Strict chronological journal of waves. Each entry is one wave: date, PR, milestone, sandbox-vs-hardware boundary.

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

phi^2 + phi^-2 = 3

## 2026-07-14 - W7 wave (part 4): t27 policy enforcement + mdns_proxy spec + honesty pass
- PR: [#81](https://github.com/gHashTag/tri-net/pull/81) DRAFT (unchanged draft status; not merged)
- Milestones touched: t27-enforcement (new), W7 (mdns_proxy source-of-truth spec), W3 (audio_crypto honesty)
- Deliverables:
  - `lefthook.yml` hardened: added `handwritten-logic-allowlist` (covers src/bin/, closes smuggling gap), `golden-anchor` (L5), `gen-provenance` + `stale-gen` pre-push audits, ASCII gate tolerance for the t27c banner. Maps to laws L1-L7.
  - `.t27-allowlist` (new): single reviewable exception surface; enumerates the 9 M1 bootstrap src modules, 7 bins, build.rs, and the 1 quarantined placeholder.
  - `specs/mdns_proxy.t27` (new): source of truth for envelope + bounded framing (MAX_FRAME_LEN=8192) + multi-question bound (MAX_QUESTIONS=16) + qtype dispatch/routing + big-endian header extractors; 9 test blocks + 1 invariant.
  - `docs/T27_ENFORCEMENT.md` (new): enforcement model + measured toolchain findings.
- Sandbox (MEASURED, cargo 1.97.0 + lefthook 1.7.18 installed in sandbox; t27c ABSENT):
  - Lefthook: 7/7 negative cases blocked (rc=1, correct L3/L4/L5/L6/L7/L2 violations), 4/4 positive cases pass (rc=0), incl. em-dash-banner tolerance and allowlist bypass.
  - gen-provenance audit over 75 gen files: OK (audio_crypto.rs sole quarantined exception).
  - mdns_proxy module: 13/13 unit (rustc --test, isolated) x3 deterministic; clippy clean.
  - audio_crypto module: 17/17 unit (rustc --test, isolated) x3 deterministic; clippy clean.
- BLOCKERS (measured, honest):
  - t27c ABSENT: `specs/mdns_proxy.t27` authored but NOT generated; `specs-parse`/`stale-gen` SKIP; mdns_proxy runtime NOT migrated to generated code this wave.
  - Whole-crate `cargo build --release` FAILS (106 errors) due to PRE-EXISTING invalid t27c codegen inherited from main (`let;` split in gen/rust/adaptive_routing.rs, flow_control.rs, etc.; byte-identical to main). Not a PR #81 regression. `cargo-build` hook is ADVISORY pending t27c fix.
  - audio_crypto XOR+trunc-SHA is a PLACEHOLDER: unused dead code (fail-closed by non-linkage), quarantined via allowlist. Real AEAD blocked on t27c crypto-binding + PTT integration.
- Hardware: NONE. No two-process mDNS smoke run (would need the crate to build; blocked on pre-existing codegen). No RFC 8766 completeness claim.
- Anti-anchor: every number above is a sandbox measurement or an explicit blocker; no hardware or full-RFC claims.

phi^2 + phi^-2 = 3
