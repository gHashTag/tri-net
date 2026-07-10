# Wave Report 2026-07-11 v2 — wire / CI-CD / seal / deep-modem surface

Scope of this wave: the surfaces prior waves did not reach — `src/wire.rs`
framing, the `.github/` CI-CD workflows, the seal / `.t27c-version` enforcement
mechanism, and the deeper `src/modem.rs` sample-domain paths. Everything below
is grounded against commit `6850649` on `main` (verified 2026-07-11).

Anchor: phi^2 + phi^-2 = 3.

---

## 1. Honesty preface (verified, not asserted)

- `main` does NOT build from a clean clone. A fresh `git clone` + `cargo build`
  fails in the build script itself:

  ```
  error[E0308]: mismatched types
  error[E0599]: no method named `map_or` found for type `{integer}`
  error: could not compile `trios-mesh` (build script) due to 4 previous errors
  ```

  Root cause is `build.rs:27-31`: `entry.metadata().map_or(0, |m| m.modified().ok())`
  gives `map_or` an integer default and an `Option<SystemTime>` closure body, then
  chains `.map_or`/`.elapsed()` on the resulting `{integer}`. This is ALREADY filed
  and fixed in unmerged PRs #59 (build) and #60 (pinned-t27c pipeline). This wave
  does NOT re-report it; it is the baseline reality every finding below sits on top of.

- Grounded counts (re-derived this wave, not quoted from memory):
  - `find specs -name '*.t27' | wc -l` -> `68` specs.
  - `grep -rE '^\s*#\[test\]' src tests | wc -l` -> `101` test attributes.
  - `ls gen/rust/*.rs | wc -l` -> `68` generated Rust modules.
  - Specs wired into `src/` business logic: `1` (`specs/wire.t27` via `src/wire.rs`),
    per PR #60's own PIPELINE.md. The other 67 gen modules compile but are unused.
  - `.trinity/seals/*.json` -> `1` seal file (`specs_MeshWire.json`), covering 1 of 68 specs.

- De-duplication done before writing. Not re-reported here: PR #59 (build + router
  split-horizon), PR #67 (routing `is_feasible`, None-branch inf route, router TTL
  pre-decrement, modem 1st-order carrier recovery, gf16 fused butterfly + bit_reverse),
  PR #69 (beacon MAC/is_fresh, guard-keys on wrong FrameKind, hello.t27 ghost spec,
  hardcoded HELLO_MAC_KEY, self_healing 8-bit cooldown, 9/68 coverage illusion,
  non-const-time MAC compare, ETX floor-bias). Crypto handshake is owner-gated
  (PR #63/#65) and untouched.

- In-flight overlap acknowledged honestly. PR #60 introduces `.t27c-version`
  (pins the compiler to `t27@4832ec6`), regenerates every `gen/rust/*.rs` under
  that pin, and rebuilds the drift-guard to glob `specs/*.t27` and fail on byte
  drift. So the "moving `ref: master`" and "hardcoded 68-spec allowlist" concerns
  are ALREADY being closed by #60 — this wave does NOT claim them. What #60 does
  NOT cover is reported below (WS2, WS3).

---

## 2. Weak-spots heatmap

Three understandable metaphors so a non-radio reader can parse the table:

- Замок и стены (castle and walls): the modem's "front gate" opens on an absolute
  push-force (WS1) — fine on the practice field where everyone weighs the same,
  wrong the moment real visitors arrive at different weights (radio gain varies).
- Тепловая карта (heat map): one hot cell in the PHY (WS1), two warm cells in the
  build/supply-chain plumbing (WS2, WS3). No new hot cells in `wire.rs` — audited clean.
- Что я реально нашёл в коде (what I actually found in the code): a sync threshold
  that assumes samples arrive at amplitude ~1; a cryptographic seal that no robot
  ever checks; and a compiler pinned to the bit while the Rust toolchain floats.

| # | Weak spot | Sev | File:line | Fix (E-id) |
|---|-----------|-----|-----------|------------|
| WS1 | Modem frame-sync gate is an ABSOLUTE correlation magnitude (`SYNC_THRESHOLD = 8.0`), not normalized to received signal energy. On the AD9361 with AGC/variable gain the Barker peak scales as `13*g*A`; a fixed 8.0 either never fires (low gain) or always fires (high gain). Invisible in `-sim` because every test symbol has amplitude 1. Blocks the first cabled-loopback / OTA RX bring-up (issues #9, #11). Secondary: `SPS = 4` is a hard oversample lock with no fractional resampler, so the ADC rate must be exactly 4x the symbol rate. | P1 | `src/modem.rs:28` (const), `:74` + `:85` (`demodulate`), `:232` (`find_timing`); `SPS` at `:128` | E2.1 |
| WS2 | The seal / FROZEN_HASH ring is inert. `.trinity/seals/` holds exactly 1 of 68 specs (`specs_MeshWire.json`, ring 12, sealed 2026-07-02) and ZERO workflow files ever read it (`grep -ril seal .github/` = 0). It records `spec_hash` + `gen_hash_{rust,c,zig,verilog}` but nothing verifies them. Post-#60 the integrity model is regenerate-and-diff, which supersedes the seal — leaving the seal a dead artifact that misleadingly implies a per-spec cryptographic freeze that CI does not enforce. | P2 | `.trinity/seals/specs_MeshWire.json`; absence across `.github/workflows/*.yml` | E3.1 |
| WS3 | Reproducibility is asymmetric: the T27 compiler is pinned to the commit (`.t27c-version`, via #60) but the Rust toolchain floats. `ci.yml:13` and the (post-#60) `spec-drift-guard.yml` both use `dtolnay/rust-toolchain@stable`. With `cargo clippy --all-targets -- -D warnings` (`ci.yml:17`) a new stable lint turns CI red with zero code change, and rustc codegen can shift under a repo whose entire thesis is deterministic builds from a pinned toolchain. No `rust-toolchain.toml` exists. | P2 | `.github/workflows/ci.yml:13,17`; `.github/workflows/spec-drift-guard.yml` (rust-toolchain step) | E1.2 |

Audited-clean (honest negatives, so the next wave does not re-walk them):

- `src/wire.rs`. `Header::parse` bounds-checks `b.len() < HEADER_LEN` before any index,
  the header is a fixed 11 bytes with no attacker-controlled length field (payload
  length is the AEAD frame boundary, not a wire field), and the serialized bytes are
  the AEAD associated data so a tampered header fails `Session::open`. The T27-first
  wrapper only re-exports generated predicates. No framing/length/bounds defect found.
- Drift-guard spec coverage. On `main` the hardcoded list equals the 68 specs on disk
  exactly (set difference is empty both ways); PR #60 replaces the list with a
  `specs/*.t27` glob anyway. No coverage gap to file.

---

## 3. Science -> prescription

### WS1 — normalize the sync metric to signal energy

An absolute matched-filter threshold is only valid when the input amplitude is
fixed. A real receiver front-end applies AGC, so the correct detector is a
correlation NORMALIZED by the local received energy (a ratio in [0,1] that is
gain-invariant), exactly the construction Schmidl and Cox use for their timing
metric `M(d) = |P(d)|^2 / R(d)^2`.

- Prescription: replace the raw `corr.norm() < SYNC_THRESHOLD` test with a
  normalized statistic `|corr| / sqrt(E_window * E_barker)` and set the threshold
  as a fraction (e.g. 0.6) of the ideal, gain-free peak. Keep `demodulate`'s coarse
  gate but make it scale-free; the AEAD tag stays the real accept/reject.
- Because this is PHY signal logic, land it spec-first via `specs/` + `t27c`, not by
  hand-editing `src/modem.rs` (see Boundary).
- Primary reference: Schmidl, Cox, "Robust Frequency and Timing Synchronization for
  OFDM," IEEE Trans. Commun. 45(12):1613-1621, 1997, DOI 10.1109/26.650240. Open-source
  normalized-correlation sync in a real SDR PHY: Jiao et al., openwifi, arXiv:2003.09525.

### WS2 — either enforce the seal or delete it

An integrity attestation that no verifier consults provides zero assurance and
negative clarity (it implies a guarantee that does not exist). The supply-chain
literature is explicit that provenance/attestation is only meaningful when a
downstream gate verifies it.

- Prescription (pick one, do not leave both): (a) add a CI step that runs
  `t27c seal <spec> --save` for every spec and fails on any `spec_hash`/`gen_hash`
  mismatch, extending the seal ring from 1/68 to 68/68; or (b) delete the single
  stale `specs_MeshWire.json` and state in `docs/PIPELINE.md` that regenerate-and-diff
  under the pinned `.t27c-version` (PR #60) is the sole integrity mechanism.
- Primary reference: SLSA v1.0, Build track (provenance is only a control when
  verified) — https://slsa.dev/spec/v1.0/ . Attestation-verification framing:
  Torres-Arias et al., "in-toto: providing farm-to-table guarantees for bits and
  bytes," USENIX Security 2019 — https://www.usenix.org/conference/usenixsecurity19/presentation/torres-arias .

### WS3 — pin the Rust toolchain to match the pinned compiler

A build is reproducible only if ALL of its inputs are pinned. Pinning `t27c` to a
commit while letting `rustc`/`clippy` float leaves a hole precisely where the repo
claims determinism, and couples green CI to whatever lint the newest stable ships.

- Prescription: add a `rust-toolchain.toml` with a pinned `channel = "1.NN.0"` and
  reference it from both workflows; the OpenSSF Scorecard "Pinned-Dependencies"
  check treats a floating toolchain as an unpinned dependency.
- Primary reference: Reproducible Builds project — https://reproducible-builds.org/docs/definition/ .
  Rustup toolchain-file spec — https://rust-lang.github.io/rustup/overrides.html#the-toolchain-file .
  OpenSSF Scorecard Pinned-Dependencies — https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies .

---

## 4. Competitor / science refresh (1 search, dated)

One freshness pass (2026-07-11). The FANET routing field continues to converge on
learned/clustered routing over the OLSR/AODV/BATMAN baselines: "Study of
Cluster-Based Routing Based on Machine Learning for UAV Networks in 6G"
(arXiv:2510.27121, Oct 2025) — https://arxiv.org/pdf/2510.27121 . On the product
side, tethered-drone mesh comms are now a packaged offering (Volarious ACE6 mesh
add-on) — https://www.volarious.com/add-on-ace6-mesh-network-cummunication .

Implication for Tri-Net's moat: the differentiator is NOT another routing heuristic
(the field is crowded and ML-driven) but the spec-first, chip-signed, reproducible
PHY-to-transport stack. That moat is undercut every day `main` does not build (WS
preface) and every place the "deterministic" claim has an unpinned input (WS2, WS3).
Fixing the plumbing is the competitive act, not a chore.

---

## 5. Four-sprint plan (measurable acceptance criteria)

Sprint 1 — unblock and close the reproducibility asymmetry
- E1.1 Land the build fix (adopt #59/#60). Files: `build.rs`, `gen/rust/*`,
  `.t27c-version`. Acceptance: `git clone` + `cargo build` + `cargo test` all green
  from a clean clone; CI `build + test` job passes. Effort: S (review/merge, owner-gated).
- E1.2 Pin the Rust toolchain (WS3). Files: new `rust-toolchain.toml`, `ci.yml`,
  `spec-drift-guard.yml`. Acceptance: both workflows resolve the pinned channel;
  a deliberate bump of a lint on newer stable does not change CI outcome. Effort: S.

Sprint 2 — modem hardware-readiness
- E2.1 Normalized sync metric (WS1), spec-first. Files: `specs/wire.t27` or a new
  `specs/modem_sync.t27` + regenerated `gen/`, consumed by `src/modem.rs`.
  Acceptance: a new host test sweeps input gain over [0.1x, 10x] and detection
  probability stays >= the amplitude-1 baseline at fixed SNR; existing modem tests
  still pass. Effort: M.
- E2.2 Document/enforce the `SPS = 4` sample-rate assumption. Files: `src/modem.rs`
  doc + a `debug_assert` or config check at the ADC boundary. Acceptance: a mismatched
  oversample ratio is rejected with a clear error rather than silently decoded wrong.
  Effort: S.

Sprint 3 — integrity hardening
- E3.1 Resolve the seal (WS2): either wire `t27c seal --verify` into CI for all 68
  specs, or delete the stale seal and document the model in `docs/PIPELINE.md`.
  Acceptance: `grep -ril seal .github/` is either > 0 with a passing 68/68 check, or
  the `.trinity/seals/` orphan is gone and PIPELINE.md states the single source of
  integrity. Effort: S-M.
- E3.2 Modem transport MTU clamp. Files: `src/modem.rs` (`ModemTransport`),
  `src/daemon.rs`. Acceptance: an IP payload that would exceed `MAX_FRAME - overhead`
  is clamped/rejected at the TUN boundary, not silently dropped at `send`. Effort: S.

Sprint 4 — verification parity
- E4.1 Golden vectors for modem sync across a gain x SNR grid. Files: `tests/` +
  fixtures. Acceptance: committed golden vectors that fail if the normalized-metric
  regression from E2.1 ever regresses. Effort: M.
- E4.2 Extend T27 spec coverage of wire framing predicates with an `invariant` that
  ties `header_byte`/`u32_be` round-trip to `parse_accepts`. Files: `specs/wire.t27`.
  Acceptance: `t27c suite` proves the invariant; drift-guard stays green. Effort: M.

---

## 6. Three cooperation lanes for the next wave

Each lane is independently startable and does not block the others.

Lane A — PHY normalization (radio/DSP contributor)
- Scope: implement WS1's normalized correlator spec-first and its gain-sweep test.
- Actor fit: someone comfortable with matched-filter DSP and the T27 spec flow.
- Deliverable: `specs/modem_sync.t27` + regenerated `gen/`, `src/modem.rs` consuming
  it, and a passing [0.1x, 10x] gain-sweep host test.
- Cite: Schmidl-Cox DOI 10.1109/26.650240; openwifi arXiv:2003.09525.
- Effort: M. Risk: medium — touches PHY; must not weaken the AEAD-is-the-real-gate
  property, and stays `-sim` until a board exists.

Lane B — Reproducibility closure (CI/release engineer)
- Scope: WS3 (pin Rust toolchain) + WS2 option (b) seal cleanup or option (a) verify.
- Actor fit: CI/supply-chain engineer; no radio knowledge needed; parallel to Lane A.
- Deliverable: `rust-toolchain.toml`, updated workflows, and either a 68/68 seal-verify
  step or a documented seal removal in `docs/PIPELINE.md`.
- Cite: reproducible-builds.org; SLSA v1.0; OpenSSF Scorecard Pinned-Dependencies.
- Effort: S-M. Risk: low — pure plumbing; verifiable only once #59/#60 make `main` green.

Lane C — Modem transport hardening (systems/Rust contributor)
- Scope: E2.2 + E3.2 — make the `SPS` assumption and the `MAX_FRAME` MTU explicit
  and fail-loud rather than silent.
- Actor fit: Rust systems contributor; independent of PHY internals and CI.
- Deliverable: MTU clamp at the TUN/transport boundary + oversample-ratio guard,
  each with a host test.
- Cite: this repo's own `src/modem.rs:30-33` overhead accounting (Header::LEN + 8 + 16).
- Effort: S. Risk: low.

---

## 7. Boundary — what this wave cannot and did not do

- This wave is AUDIT-ONLY. No fix was implemented, on purpose. Reasons, honestly:
  (1) `main` does not build, so no change could be verified end-to-end this wave;
  (2) the CI/reproducibility surface (WS2/WS3) is owned by in-flight PR #60 and a
  competing branch would create merge friction, not value; (3) the one code finding
  (WS1) is hand-written PHY signal logic, which the spec-first mandate and the
  security-adjacency of sync both put out of bounds for an unattended edit. Per the
  guardrail "if nothing is clearly safe, keep the wave audit-only," it stayed audit-only.
- No hardware. Every modem claim here is `-sim`; WS1's real-world failure mode is a
  projection about AD9361 behavior, not a measured on-device result. No board was
  flashed (issue #8 remains open).
- No merge, no push to `main`, no crypto/beacon-auth work (owner-gated, PR #63/#65).
- No fabricated metrics. Every count in the preface was re-derived by command this wave.

Anchor: phi^2 + phi^-2 = 3.
