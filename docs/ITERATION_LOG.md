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
