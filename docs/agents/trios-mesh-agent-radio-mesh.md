# Local-agent task: TRI-NET mesh — end-to-end mesh-over-modem (host-testable)

**Repo (code + issues, one repo):** `/Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net` (GitHub `gHashTag/tri-net`, LOCAL, private). Work off **`main`**. Code and the tracking issue #15 are BOTH here, so `Closes #15` in the PR body works directly. Anchor: `phi^2 + phi^-2 = 3`. (The old `trios-mesh` repo is the legacy source it was consolidated from — ignore it; work in tri-net.)
**Project:** TRI-NET drone-mesh — "Starlink without satellites": self-organizing 5.8 GHz OFDM mesh carrying internet + video + MAVLink. This task advances the RADIO link, all in software/simulation (no new hardware).

---

## Mission
Take the validated single-burst BPSK modem to an **encrypted mesh running over the modem transport, proven end-to-end in a host simulation** (simulated radio channel = fractional delay + CFO + AWGN). No OTA — Thailand bans it; host/cabled only.

## Where things stand (already on `main`, merged)
- `src/modem.rs`: BPSK core (`modulate`/`demodulate`, Barker-13 preamble) + radio-ready sample layer `tx_shaped`/`rx_recover` (RRC β0.35 sps=4, matched filter, first-excursion Barker timing, **iterative decision-directed CFO recovery**) + `ModemTransport` (in-process burst queue implementing the byte-level `Transport`). Host-fuzzed at 0 loss; CFO clean to ~0.03 cyc/sym.
- `src/daemon.rs`: the `Transport` trait (`send(&[u8])`/`recv()->Vec<u8>`) + `Node` (X25519/ChaCha20 sessions, `seal_data`/`open_data`).
- `src/crypto.rs` (M1 crypto + HKDF ratchet), `src/routing.rs` (ETX), meshd bin. Deterministic tests use an LCG+Box-Muller `Awgn` helper — **no `rand` crate**.
- KNOWN LIMITS: `rx_recover` is a SINGLE-burst decoder (locks to the first preamble; no idle-noise/multi-burst handling); sync gate thins near the CFO edge (0.03–0.038 cyc/sym, ~3% loss).

## Build & gate
```bash
cd /Users/ssdm4/Desktop/PROJECTS/CLAUDE/tri-net && git checkout main && git pull
cargo test                       # unit + integration
bash scripts/verify.sh           # cargo fmt --check + clippy -D warnings + tests  (MUST be green to commit)
```

## Increments (do IN ORDER; one small PR each)
### 1. CFO-robust STREAMING receiver
Turn `rx_recover` from single-burst into a continuous-stream receiver:
- **Idle-noise burst detection + retry-next-excursion:** when a first-excursion lock fails to `demodulate`, advance past it and try the next excursion until a frame decodes or the buffer is exhausted (don't globally commit to the first crossing).
- **Multi-burst demux:** a stream with several concatenated bursts must yield all frames in order (not just the first).
- **Normalized/differential detector:** so the Barker sync gate holds near the CFO edge instead of the ~3% loss.
**Validate with deterministic fuzz** (extend the existing LCG+Box-Muller harness): (a) prepend ~60 samples of AWGN (σ≈0.5) before a good burst → recovers across seeds; (b) 3 back-to-back bursts in one stream → all 3 recovered in order; (c) CFO 0.035–0.038 at σ0.05 → near-zero loss. Then an **adversarial refute pass**: spawn skeptics that try to break each claim; keep only what survives.

### 2. Mesh-over-modem (the headline)
Wire `ModemTransport` into the mesh so the encrypted mesh runs over the modem:
- Route a sealed `Node::seal_data` frame from node A to node C **through relay B (2 hops)**, where each hop crosses a `ModemTransport` over a **simulated radio channel** (apply fractional delay + CFO 0.01 + AWGN to the IQ between `send` and `recv`). C's `open_data` must decrypt the original payload intact.
- Add it as an integration test mirroring the existing `tests/` style (`linked()` handshake helper). Keep payload ≤220 B (255-B frame cap).
This proves multi-hop **encrypted mesh-over-radio end-to-end in simulation** — the demo-gate for the radio path.

### 3. (HARDWARE-GATED — do NOT start without confirmation)
AD9361 cabled loopback TX/RX on a Puzhi P201 Mini for a real 2-node link. Needs an **SMA cable + 30–40 dB attenuator** (OTA illegal). Leave a clean hook/trait impl (`Ad9361Transport`) and a `radio/` script stub; STOP and report on #15 rather than attempting without confirmed cabling.

## Method (what worked in this project)
- **Deterministic fuzz first** (LCG+Box-Muller, no `rand`) — it catches what fixed-value tests mask (e.g. random payload dethroning the Barker preamble → the first-excursion sync fix; tail CFO drift → the iterative DD refine).
- **Then an adversarial refute pass** — an independent skeptic per finding. This is what caught the earlier criticals (a >255 B frame panicked `send`; back-to-back sends dropped frames). Default to "refuted" if unsure.
- Small, reviewable PRs to `main`; `bash scripts/verify.sh` green; every increment adds tests. Match the existing modem.rs style and doc-comment density.

## Definition of done
- Streaming `rx_recover` fuzz-passes: leading-idle-noise recovery + 3-in-a-row multi-burst + CFO-edge near-zero loss.
- A host test routes an encrypted mesh frame **2 hops through the modem transport over a delay+CFO+AWGN channel** and decrypts it intact.
- `verify.sh` green; hardware step left as a documented gated hook.
- Open PR(s) to `gHashTag/tri-net` `main` with **`Closes #15`** in the body; log progress with `gh issue comment 15 -R gHashTag/tri-net`.

## Guardrails
- **No OTA** (Thai law) — simulated/cabled channels only. No `rand` crate (deterministic LCG). `#![forbid(unsafe_code)]`. Don't gold-plate: minimum code per increment (CLAUDE.md). If an increment balloons, commit what's safe and report the blocker on #15.
