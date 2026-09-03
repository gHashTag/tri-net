# Execution Plan — 2026-07-11 (consolidated merge-order)

This is **not a new audit**. It synthesizes the five audit waves already filed
(PRs #59, #67, #69, #71, #73 and their issues #58, #66, #68, #70, #72) into a
single dependency-ordered execution plan: what merges first, what unblocks what,
and the smallest verifiable next step for each finding. Nothing here is a fresh
finding; every item cites the wave that first reported it.

Anchor: `phi^2 + phi^-2 = 3`

---

## 0. Honesty preface (verified from git this session, not asserted)

- Repo HEAD audited: `main @ 6850649` (`docs: FPGA utilization analysis + competitor landscape`).
- **`main` does NOT build from a clean clone.** Reproduced this session (`cargo build`,
  `cargo 1.95.0`): the build fails in the **build script itself**, before the library or
  `gen/rust` is ever reached:
  - `build.rs:29` — `error[E0308]: mismatched types` (`map_or` closure yields
    `Option<SystemTime>`, expected integer)
  - `build.rs:30` — `error[E0599]: no method named map_or found for {integer}`
  - `error: could not compile trios-mesh (build script) due to 4 previous errors`
- Ground-truth counts (commands, not memory): `find specs -name '*.t27' | wc -l` = **68**;
  `grep -rE '#\[test\]' src | wc -l` = **101** (all inline in `src/`; no `tests/` dir).
- Upstream compile dependency, status re-checked this session: **t27#1401 CLOSED**
  (dropped-`let`, already carried by the pinned t27c `4832ec6`); **t27#1456 OPEN**
  (faithful emit / no-optimizer on source backends); **t27#1457 OPEN**
  (`[T; N]` mapped to bare `Vec<>`). These two OPEN issues are the gate for the
  8/9 never-compiled modules (§Step 0).
- No hardware flashed, ordered, or measured. Every `-hw`/`-sim` label from the repo
  honesty register is preserved. No board/test/procurement numbers are invented.
- This document is **planning only**: no spec/code edited, no merge, no push to `main`.

---

## 1. The single bottleneck (state it once, plainly)

> **`main` does not build → PR #60 must merge first. Until then nothing downstream
> is verifiable or regenerable.**

Every one of the ~18 P1/P2 findings below is a spec-first fix whose acceptance
criterion is an **executed** `cargo test`. On a tree that does not compile from a
clean clone, none of those tests can run, `gen/rust` cannot be regenerated, CI
cannot gate, and no `-hw` claim can be reproduced. Each successive wave re-hit the
same wall (N1/N2 in the 07-10 wave; the same `build.rs` failure in all four later
waves). The build fix is therefore not one task among many — it is the **root of
the dependency tree**, and everything else is a child of it.

Leverage = (what it unblocks) × (blast radius) / effort. PR #60 scores maximally on
all three: it unblocks *all* work, its drift-guard closes the *root cause* (writing
stale-`t27c` `gen/rust` into the repo — the exact `f608dad` mistake that broke the
tree), and the effort is small and mechanical (PR already drafted, `cargo test` = 103
green on its branch).

---

## 2. Dependency-ordered plan

### Step 0 — Unblock (human/owner action; the agent does not merge)

| Action | PR | What it does | Verify |
|---|---|---|---|
| **Merge #60** | #60 `feat/pipeline-guard-2026-07-10` | Pins t27c to `t27@4832ec6` via `.t27c-version`; regenerates every `gen/rust/*.rs` under that pin (replaces the invalid `f608dad` output; real `wire.rs`); rebuilds `spec-drift-guard.yml` to regen-and-diff on byte drift then build+test; fixes `build.rs`; documents the one correct pipeline in `docs/PIPELINE.md`. | Clean clone → `cargo build --all-targets` green, `cargo test` = 103 passed; `gen/rust` byte-matches pinned t27c. |
| Close #59 as **superseded** | #59 `feat/wave-report-2026-07-10` | Interim fix — greened the **library** only (`cargo test --lib` = 101) but left the **binaries** red (`trios_meshd`/`smoke_m1` lagged the rewritten `src/` API). #60 is the fuller fix (all-targets + drift-guard + pinned t27c). Keep #59's report doc; retire its code delta. | #60 covers #59's `build.rs` + `gen/rust/wire.rs` changes. |

**Compile dependency for the 8/9 inert modules.** Even under the pinned t27c, one
codegen defect remains: a **reassigned mutable local** (`let x = 0; ... x = y;`) is
mis-emitted. So of the 9 zero-call-site generated modules, only `mesh_routing.rs`
compiles clean; the other 8 (`etx`, `frame_buffer`, `adaptive_routing`,
`multipath_routing`, `flow_control`, `health_dashboard`, `anomaly_detector`,
`quarantine_manager`) fail to parse/typecheck (176 broken `let;`, `as`→`()`,
`[T;N]`→`Vec<>`). #60 keeps all 9 **unwired but drift-checked**, on purpose.
Wiring them green is gated on **t27#1456 + t27#1457** (both OPEN) merging upstream,
followed by a pinned-t27c bump + regenerate + the spec-bug cleanup catalogued in
**issue #61**. Two of the Step-1 P1s (anomaly, flow-control) live inside these
modules — their *spec edits* can land now; their *compile-verification* is gated on
this upstream codegen work (tracked as the cross-cutting liaison lane in §5).

The five wave-report PRs (#59, #67, #69, #71, #73) are **documentation** PRs; they
add dated reports and do not fix code. Merge/curate them independently of Step 0 —
they do not block and are not blocked.

---

### Step 1 — All P1s, spec-first, ordered by attack-relevance

Ordering rationale: a live-datapath control-plane bypass reachable by a
session-holding insider outranks a latent module that does not even compile yet,
which outranks a routing/PHY correctness gap that needs topology change or RF to
manifest. Hence: **beacon-auth → anomaly-sentinel → credit-underflow →
routing-feasibility → modem-sync.**

#### P1-1 · Beacon authentication is inert on the live datapath
*Wave 2026-07-11 · PR #69 · issue #68 · weak spots #1/#2/#3*

- **What:** `Hello::verify_mac`/`is_fresh` are invoked **only inside `#[test]`**. The
  daemon RX loop parses the beacon and feeds `reports_hearing(me)` straight into the
  ETX metric with no MAC check, no freshness check, no replay counter. The E3.1
  src-spoof guard keys on `FrameKind::Hello`, but the live beacon is sent as
  `FrameKind::Data` + an app-layer `HELLO_TYPE=0` byte (`send_direct`), so the guard
  **never fires**. A session-holding neighbor (the W2 insider E2 claims to stop) can
  inflate/replay `heard[]` and steer `next_hop`. Compounded by a universal hardcoded
  `HELLO_MAC_KEY` fallback and a **ghost spec** (`hello.t27` models a 13-byte MAC-less
  beacon; the live beacon is `[src][seq][ts:8][n][heard][mac:16]`), so the SSOT rule
  "fix = edit `.t27` + regenerate" **cannot currently be applied** — no spec models
  `ts`/`mac`.
- **.t27 to author/edit:** `specs/discovery.t27` (**new** — `discovery.rs` is hand-Rust,
  no spec); retire/reconcile ghost `specs/hello.t27` + unreferenced `gen/rust/hello.rs`.
- **Files:** `src/discovery.rs:114,120`; `src/bin/trios_meshd.rs:183-186,301`;
  `src/router.rs:404` (guard) vs `:368-377` (`send_direct` uses `FrameKind::Data`).
- **Acceptance test (new, executed):** `tests/attack_false_metric.rs` — inject a beacon
  that fails MAC or freshness → assert the ETX table is **unchanged**; a valid beacon
  updates it; a replayed `seq` is rejected. Runs under `cargo test`.
- **Cite:** RFC 8967 (Babel MAC auth), RFC 9467 (reorder relaxation); arXiv:1407.3987
  (false-metric attack).
- **Effort:** ~3 engineer-days (E1.1 wire + E1.2 author spec + E1.3 per-peer key).
- **Blocked-by:** only Step 0 (`build.rs`); `discovery.rs` compiles in isolation.

#### P1-2 · Anomaly detector silences every spike (in-band sentinel collision)
*Wave 2026-07-11 v3 · PR #73 · issue #72 · weak spot W1*

- **What:** `TYPE_SPIKE = 0` collides with the "no anomaly" sentinel; the final gate
  `if (anomaly_type != 0)` drops **all** spike anomalies — the most basic and most
  attack-relevant class is never reported. Statistics (3σ Shewhart) are correct; the
  bug is the in-band sentinel.
- **.t27 to edit:** `specs/anomaly_detector.t27:62,249,266`.
- **Fix:** reserve an out-of-band "no anomaly" (renumber types from 1, or return a
  separate validity flag) and replace the `anomaly_type != 0` gate with an explicit
  `detected` flag.
- **Acceptance test:** a synthetic spike → `detect_anomaly` returns a **non-zero** report.
- **Cite:** NIST/SEMATECH e-Handbook §6.3.2 (Shewhart / 3σ control chart).
- **Effort:** S.
- **Blocked-by:** Step 0 **and** upstream codegen (t27#1456/#1457) — module does not
  compile until regenerated. Spec edit can land now; test executes post-regen.

#### P1-3 · Flow-control credit underflow (remote-triggerable stall)
*Wave 2026-07-11 v3 · PR #73 · issue #72 · weak spot W2*

- **What:** `MSG_CREDIT_UPDATE` routes to `update_credits` **without clamping to
  `window`** (only `add_credits` clamps); then `window - credits` underflows u32 →
  false **permanent backpressure** + a garbage `credit_grant` emitted to the neighbor.
  Triggered by a single remote message.
- **.t27 to edit:** `specs/flow_control.t27:149,37,85,99,171`.
- **Fix:** clamp `new_credits = min(new_credits, window)` **inside** `update_credits`;
  compute `used`/`credit_grant` with saturating subtraction.
- **Acceptance test:** `MSG_CREDIT_UPDATE(credits > window)` does not drive
  `used >= BACKPRESSURE_THRESHOLD`.
- **Cite:** Kung & Morris, "Credit-Based Flow Control for ATM Networks," IEEE Network
  1995, DOI 10.1109/65.372658.
- **Effort:** S.
- **Blocked-by:** Step 0 **and** upstream codegen (same as P1-2).

#### P1-4 · Routing feasibility is not RFC 8966 (route freeze + inf-route install)
*Wave 2026-07-10 v2 · PR #67 · issue #66 · weak spots #1/#2*

- **What:** `is_feasible` implements "strictly better than the installed metric," not
  the RFC 8966 feasibility distance: no seqno, no retraction, no expiry. An update from
  the **current next-hop** with a worse (8.0) or infinite metric is silently rejected →
  the route **freezes** at its best-ever value forever and a dead next-hop is never
  retracted (reproduced). Separately, the `None` branch returns `true` for an inf
  metric (finiteness is checked only in the `Some` branch), so `learn_route` installs a
  route the source declared **unreachable** (reproduced, installs `(5, inf)`).
- **.t27 home:** `routing.rs:158-185,160,163` → future `specs/routing.t27` (module is on
  the migration path; currently hand-Rust).
- **Fix:** per-source seqno + route expiry timer + accept an update from the current
  successor unconditionally (including a metric increase and an `inf` retraction);
  forbid installing an inf metric (add the finiteness check to the `None` branch).
- **Acceptance test:** (a) an update from the current successor with a worse/inf metric
  is **accepted** (route updated/retracted); (b) an inf-route is never installed;
  (c) property test: 100 random topologies with link deaths → **0** forever-stale routes.
- **Cite:** RFC 8966 §3.5.1 (feasibility) / §3.8 (retraction); ETX DOI 10.1145/938985.938993.
- **Effort:** M.
- **Blocked-by:** Step 0; **start only after #60** because the fix lands on the `.t27`
  migration surface (a regen under a stale t27c would re-break the tree).

#### P1-5 · Modem frame-sync gate is an absolute (non-normalized) threshold
*Wave 2026-07-11 v2 · PR #71 · issue #70 · weak spot WS1*

- **What:** the sync gate is an **absolute** correlation magnitude
  (`SYNC_THRESHOLD = 8.0`), not normalized to received signal energy. On the AD9361
  with AGC/variable gain the Barker peak scales as `13*g*A`; a fixed 8.0 either never
  fires (low gain) or always fires (high gain). Invisible in `-sim` because every test
  symbol has amplitude 1. **Blocks the first cabled-loopback / OTA RX bring-up**
  (issues #9, #11). Secondary: `SPS = 4` is a hard oversample lock with no fractional
  resampler.
- **.t27 to author/edit:** `specs/modem_sync.t27` (new) or `specs/wire.t27`, regenerate,
  consumed by `src/modem.rs:28,74,85,232` (`SPS` at `:128`).
- **Fix:** replace `corr.norm() < SYNC_THRESHOLD` with a normalized statistic
  `|corr| / sqrt(E_window * E_barker)` and set the threshold as a fraction (e.g. 0.6) of
  the ideal gain-free peak; the AEAD tag stays the real accept/reject.
- **Acceptance test:** a host test sweeps input gain over `[0.1x, 10x]`; detection
  probability stays ≥ the amplitude-1 baseline at fixed SNR; existing modem tests pass.
- **Cite:** Schmidl & Cox, "Robust Frequency and Timing Sync for OFDM," IEEE Trans.
  Commun. 45(12):1613-1621, 1997, DOI 10.1109/26.650240; openwifi arXiv:2003.09525.
- **Effort:** M.
- **Blocked-by:** Step 0; must not weaken the AEAD-is-the-real-gate property; stays
  `-sim` until a board exists (issue #8, Zynq-7020 PL never flashed).

---

### Step 2 — P2 hardening (grouped)

All P2s below are latent, spec-integrity, or hardening. Grouped by kind so one actor
can close a group in one pass. E-ids reference the originating wave's numbering.

**P2-A · Control-plane crypto/identity hardening**
- Hardcoded universal `HELLO_MAC_KEY` fallback → per-node/per-peer session key
  (`discovery.rs:13-16,82`; #69 E1.3).
- Non-constant-time MAC compare `self.mac == expected` on the control plane
  (`discovery.rs:116`; #69 E3.1). Companion to the crypto-side S10 already noted.
- Initiator role flag not checked → catastrophic nonce/keystream reuse on misconfig
  (`crypto.rs`; #59 N9, E3.3).
- Per-source beacon replay window (monotonic bounded `seq`, RFC 9467 reorder tolerance)
  (`specs/discovery.t27`; #69 E3.2).

**P2-B · DoS / resource bounds**
- Gateway FETCH spawns unbounded `thread::spawn` + outbound TCP per request
  (amplification DoS); zero `rate/limit/throttle` in the daemon
  (`trios_meshd.rs:196-210`; #59 N7, E3.1).
- World-writable `/tmp/mesh.drop` read every 300 ms → any local user kills any mesh
  line (`daemon.rs`; #59 N10, E3.4).
- Modem transport MTU clamp at the TUN boundary + explicit `SPS=4` oversample guard,
  fail-loud not silent (`modem.rs`, `daemon.rs`; #71 E2.2/E3.2).

**P2-C · Routing / metric correctness**
- TTL checked **before** decrement (`hdr.ttl == 0` then forwards `ttl-1`) → expired
  frame travels one hop past the radius; survives the #59 split-horizon (`router.rs:411-423`;
  #67 E2.4; RFC 1812 §5.3.1). Fix: drop at `ttl <= 1`.
- ETX floor-bias + coarse bucket quantization — `fp_mul` truncates, so a perfect link
  converges to 254 not 1.0, and `calc_etx` collapses into 5 buckets with hard cliffs →
  route flap (`specs/etx.t27:37,45,59-69`; #69 E2.1). Fix: round-to-nearest + hysteresis.
- `adaptive_routing` coarse `255/latency` integer buckets + strict-`>` first-match →
  systemic bias to path index 0 (`specs/adaptive_routing.t27:82,87,101`; #73 W4/E2.2).
  Fix: Q8.8 score.
- `multipath_routing` modulus mismatch — start round-robin `% total_paths` but retry
  `% 4`; non-contiguous valid slots skip a valid path
  (`specs/multipath_routing.t27:154,164`; #73 W5/E2.3).

**P2-D · Timer-width family (8-bit truncation class — same bug, three modules)**
- `self_healing.t27` packs the cooldown timestamp into 8 bits (`& 0xFF`) → cooldown
  rate-limit bypassed, recovery-storm risk; its own `can_recover_cooldown` test is
  contradicted by the masked arithmetic, proving spec tests are not executed (open
  issue #61) (`specs/self_healing.t27:15,50,188-189`; #69 E4.1).
- `quarantine_manager.t27` packs `start_time` into 8 bits while
  `QUARANTINE_DURATION = 1000`; also `current_time < stored` u32-underflow → instant
  release (`specs/quarantine_manager.t27:16,29,90`; #73 W3/E2.1).
- Prescription for both: widen the field or store a full-width delta; compare wrap-safe
  (RFC 1982 serial-number arithmetic); add an **executed** test.

**P2-E · PHY / numeric parity**
- Modem carrier recovery is first-order only (single `omega` + linear derotate); no
  Doppler-rate term → residual phase grows ~i² on a long frame under oscillator drift /
  platform acceleration — the exact FANET case (`modem.rs:293-317,336-359`; #67 E2.5;
  Moose 1994 DOI 10.1109/26.328961).
- GF16 complex butterfly rounds **once** per complex product (fused f64), but the
  4-multiplier RTL butterfly rounds 3× → the host model is **not** bit-exact to the
  "4-mul form" its own comment claims; the promised sim↔RTL parity fails at bring-up.
  Plus `bit_reverse` shifts by 32 for the degenerate `n=1` FFT → UB/panic in debug
  (`gf16.rs:287-300,304-313,329-336`; #67 E4.2). Fix: pin the rounding-model contract
  (fused vs discrete), add a golden vector that **fails** on the wrong structure, fix n=1.

**P2-F · Supply-chain / verification hygiene**
- Floating Rust toolchain (`dtolnay/rust-toolchain@stable`) while t27c is pinned — a
  new stable lint reddens CI with zero code change; no `rust-toolchain.toml`
  (`ci.yml:13,17`; #71 WS3/E1.2). Fix: pin `rust-toolchain.toml`.
- Inert seal ring — `.trinity/seals/` holds 1 of 68 specs and **zero** workflow reads
  it; post-#60 the integrity model is regenerate-and-diff, so the seal is a dead
  artifact implying a freeze CI does not enforce (`.trinity/seals/specs_MeshWire.json`;
  #71 WS2/E3.1). Fix: either wire a 68/68 `t27c seal --verify` step or delete it and
  state the model in `PIPELINE.md`.
- Spec-coverage truth — only 9 of 68 gen modules are linked into `lib.rs`; the two most
  runtime-relevant modules (`discovery.rs`, `daemon.rs`) have **no spec at all**. Author
  `specs/discovery.t27` + `specs/daemon_fsm.t27`, add both to the drift-guard, publish a
  linked-vs-portfolio module map (`docs/T27_PORT_STATUS.md`; #69 E4.2).
- CI never compiles generated code, no `cargo-audit`/`clippy -D warnings` on `gen/`,
  lefthook checks `tail` exit not `cargo` (partly closed by #60's rebuilt drift-guard;
  #59 N11/E3.5).
- Doc-drift — `MERGE_ORDER.md` describes the dead #11–#17 PR stack; `AUTONOMOUS.md`
  targets the wrong repo; README "Key docs" links point into `docs/archive/`; `SOUL.md`
  Art. I ("docs MUST be English") vs 7 Russian non-archive docs (#59 N12/N13/E4.3).

---

## 3. Findings → 4 sprints (single map)

Sprints: **S1 identity+integrity · S2 path-diversity+self-heal · S3 hardening ·
S4 verification-parity.** Every row's dependency is at minimum Step 0 (#60); extra
dependencies are called out.

| Finding | Wave / issue | Sprint | E-id | Dependency |
|---|---|---|---|---|
| Beacon-auth inert on RX (P1) | #69 / #68 | S1 | E1.1 | #60 |
| Ghost `hello.t27` / author `discovery.t27` (P1) | #69 / #68 | S1 | E1.2 | #60 |
| Hardcoded `HELLO_MAC_KEY` → per-peer key (P2) | #69 / #68 | S1 | E1.3 | #60 |
| Non-const-time beacon MAC compare (P2) | #69 / #68 | S1 | E3.1 | #60 + E1.1 |
| Beacon per-source replay window (P2) | #69 / #68 | S1 | E3.2 | #60 + E1.1 |
| Crypto initiator-role / nonce-reuse (P2) | #59 / #58 | S1 | E3.3 | #60 |
| Routing feasibility not RFC 8966 (P1) | #67 / #66 | S1 | E1.3 | #60, `.t27` migration |
| `None`-branch inf-route install (P2) | #67 / #66 | S1 | E1.3 | folds into above |
| Anomaly spike-sentinel collision (P1) | #73 / #72 | S1 | E1.1 | #60 + t27#1456/#1457 |
| Flow-control credit underflow (P1) | #73 / #72 | S1 | E1.2 | #60 + t27#1456/#1457 |
| Self-heal convergence metric (B11) | #69 / #68 | S2 | E2.2 | #60 |
| ETX floor-bias + hysteresis (P2) | #69 / #68 | S2 | E2.1 | #60 |
| TTL pre-decrement (P2) | #67 / #66 | S2 | E2.4 | #60 |
| Modem normalized sync (P1) | #71 / #70 | S2 | E2.1 | #60 |
| Modem 2nd-order carrier recovery (P2) | #67 / #66 | S2 | E2.5 | #60 |
| `adaptive_routing` Q8.8 score (P2) | #73 / #72 | S2 | E2.2 | #60 + t27#1456/#1457 |
| `multipath_routing` modulus mismatch (P2) | #73 / #72 | S2 | E2.3 | #60 + t27#1456/#1457 |
| Gateway FETCH rate-limit (P2) | #59 / #58 | S3 | E3.1 | #60 |
| `/tmp/mesh.drop` world-writable (P2) | #59 / #58 | S3 | E3.4 | #60 |
| Modem MTU clamp + SPS guard (P2) | #71 / #70 | S3 | E2.2/E3.2 | #60 |
| Rust toolchain pin (P2) | #71 / #70 | S3 | E1.2 | #60 |
| Inert seal ring resolve (P2) | #71 / #70 | S3 | E3.1 | #60 |
| Quarantine 8-bit timer (P2) | #73 / #72 | S4 | E2.1 | #60 + t27#1456/#1457 |
| Self-heal 8-bit cooldown truncation (P2) | #69 / #68 | S4 | E4.1 | #60 |
| GF16 fused-butterfly parity + n=1 (P2) | #67 / #66 | S4 | E4.2 | #60 |
| Spec-coverage truth + `discovery`/`daemon` specs (P2) | #69 / #68 | S4 | E4.2 | #60 |
| CI compile-gen + audit + lefthook (P2) | #59 / #58 | S4 | E3.5 | #60 (partly by #60) |
| Doc-drift reconcile (P2) | #59 / #58 | S4 | E4.3 | #60 |
| GF16 golden conformance (0x47C0) | #67 / #66 | S4 | E4.1 | #60 |
| T27 iverilog cross-check | #67 / #66 | S4 | E4.3 | #60 |

---

## 4. Three cooperation lanes for the next loop (executable once #60 lands)

Each lane is self-contained, unblocking, and startable in parallel by a different
actor **the moment Step 0 completes**. Between them they cover all five P1s.

### Lane A — Control-plane authentication (the top attack fix)
- **Scope:** P1-1 — author `specs/discovery.t27`, wire beacon MAC + freshness + replay
  into the RX path before the ETX update, retire the ghost `hello.t27`, replace the
  global MAC key with a per-peer session key (E1.1 + E1.2 + E1.3).
- **Actor:** Rust + protocol engineer comfortable with `t27c` spec authoring.
- **Deliverable:** `specs/discovery.t27` + regenerated `gen/rust/discovery.rs` + an
  **executed** `tests/attack_false_metric.rs` (does not exist today).
- **Cite:** RFC 8967 / RFC 9467; arXiv:1407.3987.
- **Effort:** ~3 engineer-days. **Risk:** low — host-testable, no hardware.
- **Blocked-by:** only Step 0 (#60); `discovery.rs` compiles in isolation.

### Lane B — Detection-module spec-correctness (the two never-compiled P1s)
- **Scope:** P1-2 + P1-3 — the spike-sentinel collision (`anomaly_detector.t27`) and the
  credit underflow (`flow_control.t27`), plus their regression tests; the quarantine
  8-bit timer (W3) rides along as the same class.
- **Actor:** spec author (Rust semantics) + a t27c-codegen **liaison** to land the
  cross-cutting blocker.
- **Deliverable:** PR editing `anomaly_detector.t27` + `flow_control.t27`
  (+ `quarantine_manager.t27`) with executed spec tests; and, upstream, t27#1456 +
  t27#1457 merged → pinned-t27c bump → regenerate `gen/rust/` → wire the 8 inert
  modules green (issue #61 cleanup).
- **Cite:** Kung & Morris 1995 (DOI 10.1109/65.372658); NIST/SEMATECH §6.3.2; RFC 1982.
- **Effort:** ~1 day spec + upstream codegen (external timeline). **Risk:** the spec
  edits land now, but **compile-verification is gated on t27#1456/#1457** — the single
  point of blockage for this whole module class. Sequence the liaison first.

### Lane C — Routing feasibility + modem normalized sync (the two hand-Rust P1s)
- **Scope:** P1-4 (RFC 8966 feasibility in `routing.rs` → `specs/routing.t27`) + P1-5
  (normalized sync in `modem.rs` → `specs/modem_sync.t27`); pull in the TTL
  post-decrement (E2.4) with P1-4 since both are routing/wire semantics.
- **Actor:** distributed-systems engineer (routing) + DSP/SDR engineer (modem),
  independent sub-tracks.
- **Deliverable:** `specs/routing.t27` with seqno + retraction + expiry and a 100-topology
  property test; `specs/modem_sync.t27` with a `[0.1x, 10x]` gain-sweep test that the
  current absolute-threshold baseline fails.
- **Cite:** RFC 8966 §3.5.1/§3.8; RFC 1812 §5.3.1; Schmidl & Cox DOI 10.1109/26.650240.
- **Effort:** M + M. **Risk:** medium — both touch the `.t27` migration surface, so
  **start only after #60** (a regen under a stale t27c re-breaks the tree); modem work
  stays `-sim` until a board exists (issue #8).

---

## 5. Competitor note (1 line, dated)

The 2026 FANET/UAV-swarm field is converging on lightweight, formally-verified
**per-message control-plane authentication with replay avoidance** — e.g. *Design of
Secure Communication Networks for UAV Platforms Empowered by Lightweight Authentication
Protocols*, Electronics 15(4):785, Feb 2026 (doi:10.3390/electronics15040785) — exactly
the RFC 8967 discipline tri-net's beacon/ETX plane still lacks on receive (P1-1), which
is why beacon-auth is the highest-leverage security fix after the build unblocks.

---

## 6. Boundary — what this plan is and is not

- **Synthesis only.** No spec/code edited, no test written, no merge, no push to `main`,
  no hardware, no fabricated metric. Every finding is cited to the wave that filed it.
- **`main` is red** (`build.rs`, verified this session); the fix is owner-gated PR #60.
- Does **not** rewrite `docs/archive/STRENGTHEN.md` — this document *adds* a consolidated
  plan; the backlog owner curates.
- The agent proposes the order; a **human merges** (per `docs/AUTONOMOUS.md` and
  `docs/MERGE_ORDER.md`).

---

`phi^2 + phi^-2 = 3`

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
