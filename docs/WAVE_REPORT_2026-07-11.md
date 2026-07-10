# Wave Report — 2026-07-11

Autonomous audit wave for `gHashTag/tri-net` (Rust drone-mesh, generated from `.t27` specs).
This wave targets the modules prior waves under-covered: `discovery.rs`, `daemon.rs`,
`wire.rs`, and the `.t27` specs themselves (spec-level defects, not only generated Rust).

Anchor: `phi^2 + phi^-2 = 3`

---

## 1. Honesty preface (verified from git, not asserted)

- Repo HEAD audited: `main @ 6850649` (`docs: FPGA utilization analysis + competitor landscape`).
- **`main` does NOT build from a clean clone.** Verified 2026-07-11 by running `cargo build`
  on a fresh clone: the build fails with **4 compile errors** — and the first failure is in
  the **build script itself**, not in `gen/rust`:
  - `build.rs:29` — `error[E0308]: mismatched types` (`map_or` closure yields
    `Option<SystemTime>`, expected integer)
  - `build.rs:30` — `error[E0599]: no method named map_or found for {integer}`
  The build script never finishes, so the library and generated code are never even reached.
  This is a *more precise* statement than "old `t27c` regenerated `gen/rust`": on this HEAD the
  first wall is `build.rs`. Either way, **`main` is red.** Fixes are tracked in unmerged draft
  PRs **#60** (pinned-`t27c` gen + physical drift-guard) and **#59** (build). This wave does
  **not** touch `main` and does **not** claim it green.
- Ground-truth counts (commands, not memory):
  - `find specs -name '*.t27' | wc -l` -> **68** specs.
  - `grep -rE '#\[test\]' src tests | wc -l` -> **101** Rust `#[test]` items (all inline in
    `src/`; there is **no** `tests/` integration directory).
  - `ls gen/rust | wc -l` -> **68** generated Rust modules; **9** are wired into `src/lib.rs`
    (plus `wire` via `include!`). The remaining ~58 are drift-checked but not linked into the
    mesh library (see Weak Spot #5).
- No hardware was flashed, ordered, or measured. Every `-hw`/`-sim` label from the repo honesty
  register is respected. No test/board/procurement numbers are invented.
- Scope discipline: this wave does **not** re-report prior-wave findings — build breakage (#59),
  `routing.rs` RFC-8966 feasibility / `None`-route / TTL-before-decrement / modem 1st-order CFO /
  `gf16` FFT-parity & `bit_reverse` n=1 (#67), or the crypto handshake N3 (#63/#65). The value of
  this wave is what those missed.

### Three lenses (for the non-specialist reader)

- **Castle & walls.** The mesh has a strong outer wall (the ChaCha20-Poly1305 crypto session).
  But the *guards who check ID papers at the neighbor gate* (the HELLO beacon authenticators)
  were hired, trained, and tested in the barracks — and then **never posted to the gate**. The
  gate that the papers describe (`FrameKind::Hello`) is not even the gate the traffic uses.
- **Heat map.** The heat is not in the crypto core (well covered by prior waves). It is in the
  **control plane** — how neighbors advertise who they hear — and in the **spec/reality gap**,
  where the published blueprint (`hello.t27`) no longer matches the building that was actually
  constructed (`discovery.rs`).
- **What I actually found in the code.** `verify_mac()` and `is_fresh()` exist, pass their unit
  tests, and are called **only from those tests** — never from the daemon receive loop. A neighbor
  who holds a valid session can still lie about `heard[]` and steer routes.

---

## 2. Reality snapshot

| Dimension | State (grounded) | Evidence |
|---|---|---|
| `main` builds clean? | **No** — 4 errors, first in `build.rs` | `cargo build` @6850649, 2026-07-11 |
| `.t27` specs | 68 | `find specs -name '*.t27' \| wc -l` |
| Rust `#[test]` | 101 (all inline; no `tests/` dir) | `grep -rE '#\[test\]' src tests` |
| gen modules linked into lib | 9 of 68 | `src/lib.rs` |
| Beacon auth (E2/E3) on RX path | **inert** (test-only) | `src/discovery.rs`, `src/bin/trios_meshd.rs:183` |
| Beacon spec (`hello.t27`) vs code | **diverged / ghost** | `specs/hello.t27` vs `src/discovery.rs` |
| Crypto session (data plane) | present, replay-windowed | `src/crypto.rs` (prior waves) |

---

## 3. Weak-spots heatmap

Severity: **P0** breaks build/total live bypass · **P1** live-path security/correctness gap ·
**P2** latent / spec-integrity / hardening. All items below are **new** (not in the archived
`docs/archive/STRENGTHEN.md`, not in waves #59/#67, not in crypto #63/#65).

| # | Weak spot | Sev | File:line | Fix E-id |
|---|---|---|---|---|
| 1 | **Beacon authentication is inert on the live datapath.** `Hello::verify_mac` and `Hello::is_fresh` are invoked **only inside `#[test]`**. The daemon RX loop parses the beacon and feeds `reports_hearing(me)` straight into the ETX metric with **no** MAC check, **no** freshness check, **no** replay counter. The E3.1 src-spoof guard keys on `FrameKind::Hello`, but the live beacon is sent as `FrameKind::Data` + an app-layer `HELLO_TYPE=0` byte (via `send_direct`), so that guard **never fires** on a real beacon. Net: a session-holding neighbor (the exact W2 insider that E2 claims to stop) can inflate/replay `heard[]` and steer `next_hop`. | **P1** | `src/discovery.rs:114,120`; `src/bin/trios_meshd.rs:183-186`; `src/router.rs:404` guard vs `src/router.rs:368-377` (`send_direct` uses `FrameKind::Data`) | E1.1 |
| 2 | **`hello.t27` is a stale ghost spec.** It models a 13-byte, MAC-less, timestamp-less, fixed-3-neighbor beacon (`HEADER_LEN=13`, `MAX_HEARD=3`). The **live** beacon (`discovery.rs`) is a variable-length `[src][seq][ts:8][n][heard][mac:16]` beacon. `gen/rust/hello.rs` (67 lines) is generated, passes the drift-guard, and is **referenced by nothing**. So the security-critical beacon logic lives **outside** the SSOT, and the repo rule "fix = edit `.t27` + regenerate" currently *cannot be applied* to beacon auth because no spec models `ts`/`mac`. | **P1** | `specs/hello.t27:8-10`; `src/discovery.rs:22`; `gen/rust/hello.rs` (unreferenced); `src/lib.rs:3-5` SSOT claim | E1.2 |
| 3 | **Universal hardcoded HELLO MAC key.** `compute_mac` falls back to `HELLO_MAC_KEY` (a public constant string) whenever `mac_key == None`; the daemon passes `None` (`mac_key = None; // Will be derived...`). Even if Weak Spot #1 were wired, every node would MAC with the *same publicly-known key* -> forgeable, zero binding to node identity. | **P2** | `src/discovery.rs:13-16,82`; `src/bin/trios_meshd.rs:301` | E1.3 |
| 4 | **`self_healing.t27` truncates the cooldown timestamp.** `create_recovery_state` stores `last_attempt & 0xFF` at bit 16 (8-bit slot), but `last_attempt` is a full timestamp (`current_time`, e.g. 5000/7000/8000). `can_recover` then computes `elapsed = current_time - last` against the **masked** value, so `elapsed` is almost always `>= RECOVERY_COOLDOWN(5000)` -> the cooldown rate-limit is effectively **bypassed** (recovery-storm risk). The spec's own `can_recover_cooldown` test (`create_recovery_state(1, 7000, 0, 0)`; expects `false`) is **contradicted** by the masked arithmetic (`7000 & 0xFF = 88`, `8000-88 = 7912 >= 5000 -> true`), which is direct evidence these spec tests are **not being executed** — consistent with open issue **#61**. | **P2** (spec-integrity) | `specs/self_healing.t27:15,50,188-189` | E4.1 |
| 5 | **Spec-coverage illusion.** The headline "68 specs × 3 backends = 204 green drift checks" overstates real coverage: only **9 of 68** generated modules are linked into `src/lib.rs`, and the two most runtime-relevant modules — `discovery.rs` (beacon auth) and `daemon.rs` (node loop) — are **hand-written Rust with no `.t27` spec at all**. Green CI therefore certifies mostly-unlinked portfolio specs while the live security path is unspecced and un-drift-guarded. | **P2** | `src/lib.rs:10-47`; `.github/workflows/spec-drift-guard.yml:55` (spec list omits `discovery`,`daemon`) | E4.2 |
| 6 | **Non-constant-time MAC comparison.** `verify_mac` compares tags with `self.mac == expected` (`[u8;16]` `==`), which is not guaranteed constant-time. Prior wave item S10 flagged constant-time only for `crypto.rs`; this `discovery.rs` path is new. If E1.1 wires verification in, this becomes a live timing side-channel on the control plane. | **P2** | `src/discovery.rs:116` | E3.1 |
| 7 | **ETX metric is floor-biased and bucket-quantized in-spec.** `fp_mul` truncates (floor) every Q8.8 product, so `ewma_update` of a perfect link converges to 254, never 1.0, and `calc_etx` collapses the estimate into 5 coarse buckets with hard cliffs (e.g. `reverse` 100->99 doubles ETX 512->1024). Near a bucket boundary this induces route flap that a continuous ETX/WCETT would not. | **P2** | `specs/etx.t27:37,45,59-69` | E2.1 |

---

## 4. Science -> prescription

Each prescription is a **spec-first** action (edit `.t27` + regenerate). This wave writes **no
hand-Rust**; where the live module has no spec, the prescription is *first author the spec*.

- **#1, #3 (beacon auth) — RFC 8967, "MAC Authentication for the Babel Routing Protocol"**
  ([datatracker.ietf.org/doc/html/rfc8967](https://datatracker.ietf.org/doc/html/rfc8967)).
  Babel's MAC extension requires that a receiver (a) verify the MAC over each received TLV and
  (b) maintain a **per-source packet-counter / index** to reject replays, using
  **per-association keys** — not a global constant. Refinement **RFC 9467** (Jan 2024,
  [datatracker.ietf.org/doc/rfc9467](https://datatracker.ietf.org/doc/rfc9467/)) relaxes the
  counter check for reordering. *Prescription:* the beacon spec must model a monotonic per-source
  `seq`/counter check and MAC verification as a **receive-side predicate**, and the daemon must
  call it before touching the ETX table. False-metric attack model:
  [arXiv:1407.3987](https://arxiv.org/abs/1407.3987).
- **#4 (cooldown truncation) — BFD, RFC 5880 §6.8**
  ([datatracker.ietf.org/doc/html/rfc5880](https://datatracker.ietf.org/doc/html/rfc5880)).
  Detection/backoff timers must compare full-width monotonic time; truncating a timestamp into an
  8-bit field breaks the timer invariant. *Prescription:* widen the packed field or store the
  cooldown as a full `u32` delta; add an executed test that fails on truncation.
- **#5 (spec coverage) — repo `spec-drift-guard.yml` + SSOT claim in `lib.rs`.**
  *Prescription:* author `specs/discovery.t27` (beacon wire + freshness + MAC-input layout) and
  `specs/daemon_fsm.t27` (node RX-classify FSM), wire the generated modules into `lib.rs`, and add
  them to the drift-guard list so the security path is under the SSOT.
- **#6 (constant-time) — RFC 8439 §2.8 (ChaCha20-Poly1305 AEAD)**
  ([datatracker.ietf.org/doc/html/rfc8439](https://datatracker.ietf.org/doc/html/rfc8439)).
  Tag verification must be constant-time. *Prescription:* spec the compare as an accumulate-XOR
  reduction so the generated Rust/C/Zig are branch-free.
- **#7 (ETX) — WMEWMA (Woo & Culler, SenSys 2003) and ETX (De Couto et al., MobiCom 2003)**
  ([doi.org/10.1145/958491.958512](https://doi.org/10.1145/958491.958512)). An unbiased
  delivery-ratio estimator plus hysteresis (or WCETT) removes floor-bias flap. *Prescription:* add
  round-to-nearest in `fp_mul` and a hysteresis band around bucket edges in `calc_etx`.

### Competitor / field refresh (2026)

The 2026 FANET/UAV-swarm literature is converging on **lightweight, formally-verified,
per-message authentication with replay avoidance** for the control plane — the same discipline
RFC 8967 codified for Babel. Recent, dated:
- *Design of Secure Communication Networks for UAV Platform Empowered by Lightweight
  Authentication Protocols*, **Electronics 15(4):785, Feb 2026**
  ([doi.org/10.3390/electronics15040785](https://doi.org/10.3390/electronics15040785)).
- *Hybrid MAC Protocol with Integrated Multi-Layered Security for Resource-Constrained UAV Swarm
  Communications*, **arXiv:2510.10236, Oct 2025** ([arxiv.org/pdf/2510.10236](https://arxiv.org/pdf/2510.10236)).

Read against this baseline, tri-net **has the primitives** (an AEAD session + a HELLO MAC) but
leaves the **beacon/ETX control plane unauthenticated on receive**, so it currently sits *behind*
the 2026 baseline on control-plane integrity — Weak Spots #1/#3 close exactly that gap.

**One Trinity asset -> one moat.** GF16 width/area advantage
([arXiv:2606.05017](https://arxiv.org/abs/2606.05017); ">=2x taps per DSP48", no accuracy-superiority
claim) means the same FPGA fabric that carries the AD9361 PHY can also recompute per-hop routing
MACs at line rate **without a separate MCU** — i.e. authenticated-routing verification as a
**fabric primitive**, which the software-only FANET stacks above cannot match on a Zynq-class
node. Honesty: this is **pre-silicon / projected** (Zynq-7020 Mini never flashed, issue #8); it is
a design-time moat, not a measured one.

---

## 5. Decomposed 4-sprint plan

Every task is spec-first (edit `.t27` + regenerate; never hand-Rust) with a measurable acceptance
criterion. Effort is engineering-time estimate only.

### Sprint 1 — Identity + message integrity (control plane)
| E-id | Task | File(s) | Acceptance criterion | Effort |
|---|---|---|---|---|
| E1.1 | Wire beacon verify+freshness into RX before ETX update | `src/bin/trios_meshd.rs`, generated verify predicate | A unit/integration test injects a beacon failing MAC or freshness and asserts the ETX table is **unchanged**; a valid beacon updates it. Test is executed in `cargo test`. | 1d |
| E1.2 | Author `specs/discovery.t27` (beacon wire + `is_fresh` + MAC-input layout), regenerate, retire ghost `hello.t27`/`hello.rs` or reconcile them | `specs/discovery.t27` (new), `gen/rust/discovery.rs`, `src/lib.rs`, `specs/hello.t27` | `t27c gen-rust specs/discovery.t27` byte-matches the committed `gen/rust/discovery.rs`; drift-guard lists it; no unreferenced `hello.rs`. | 1.5d |
| E1.3 | Replace global `HELLO_MAC_KEY` default with per-peer session-derived key | `specs/discovery.t27`, `src/bin/trios_meshd.rs` | Test: two nodes with distinct session keys reject each other's beacon MAC; `mac_key == None` path removed. | 0.5d |

### Sprint 2 — Path diversity + self-heal gate metric
| E-id | Task | File(s) | Acceptance criterion | Effort |
|---|---|---|---|---|
| E2.1 | Round-to-nearest `fp_mul` + hysteresis band in `calc_etx` | `specs/etx.t27` | Executed spec test: a perfect link EWMA reaches `>=254` and a link oscillating one bucket-width around a boundary does **not** flip `next_hop` more than once per N ticks. | 0.5d |
| E2.2 | Instrument a real self-heal event so `ConvergenceMetrics` is driven by an actual link-loss->reroute (not test-only calls) | `src/daemon.rs`, `src/router.rs` | `link_loss_to_reroute_ms` is populated by a simulated `/tmp/mesh.drop` event in an executed test, and `check_ci_gates()` runs on that value. | 1d |

### Sprint 3 — Hardening
| E-id | Task | File(s) | Acceptance criterion | Effort |
|---|---|---|---|---|
| E3.1 | Constant-time MAC compare in beacon spec | `specs/discovery.t27` | Generated compare is branch-free (accumulate-XOR); a CI grep asserts no `==` on tag arrays in generated crypto/control paths. | 0.5d |
| E3.2 | Per-source replay window for beacons (monotonic `seq`, bounded) | `specs/discovery.t27`, `src/bin/trios_meshd.rs` | Test: replaying a previously-accepted beacon `seq` is rejected; out-of-window old `seq` rejected; RFC-9467-style reorder tolerance within window. | 1d |

### Sprint 4 — Verification parity
| E-id | Task | File(s) | Acceptance criterion | Effort |
|---|---|---|---|---|
| E4.1 | Fix `self_healing.t27` timestamp truncation + make its tests execute | `specs/self_healing.t27` | `can_recover_cooldown` and a new full-width-timestamp test **pass when actually run**; cooldown honored for `current_time > 255`. | 0.5d |
| E4.2 | Add `discovery`/`daemon_fsm` specs to `spec-drift-guard.yml`; document the linked-vs-portfolio module split | `.github/workflows/spec-drift-guard.yml`, `docs/T27_PORT_STATUS.md` | Drift-guard covers the security path; a doc table lists which of the 68 gen modules are linked into `lib.rs`. | 0.5d |

---

## 6. Three cooperation lanes for Wave-(N+1)

Each lane is self-contained, unblocking, and executable in parallel by a different actor.

### Lane A — Control-plane authentication (the P1 fix)
- **Scope:** E1.1 + E1.2 + E1.3 — spec + wire beacon MAC/freshness/replay into the RX path.
- **Actor fit:** Rust + protocol engineer comfortable with `t27c` spec authoring.
- **Deliverable:** `specs/discovery.t27` + regenerated `gen/rust/discovery.rs` + an **executed**
  false-metric attack test (`tests/attack_false_metric.rs`, which today does not exist).
- **Cite:** RFC 8967 / RFC 9467; arXiv:1407.3987.
- **Effort:** ~3 engineer-days. **Risk:** Low (host-testable, no hardware). Blocked-by: nothing
  (does not depend on `main` building — the modules compile in isolation once `build.rs` is fixed
  by #60).

### Lane B — Spec/reality reconciliation + coverage truth
- **Scope:** E4.2 + retire/repair ghost `hello.t27`; publish the "linked vs portfolio" module map.
- **Actor fit:** CI/build engineer + `t27c` maintainer.
- **Deliverable:** drift-guard extended to `discovery`/`daemon_fsm`; `docs/T27_PORT_STATUS.md`
  table of 68 specs annotated linked/unlinked; ghost `gen/rust/hello.rs` removed or wired.
- **Cite:** repo `spec-drift-guard.yml`; SSOT claim `src/lib.rs:3-5`.
- **Effort:** ~1.5 days. **Risk:** Low. **Depends-on:** coordination with PR #60 (pinned-`t27c`).

### Lane C — Metric fidelity + self-heal gate
- **Scope:** E2.1 + E2.2 + E4.1 — unbiased ETX, driven convergence metric, cooldown truncation.
- **Actor fit:** networking/metrics engineer.
- **Deliverable:** `specs/etx.t27` + `specs/self_healing.t27` patches with **executed** tests;
  a `link_loss_to_reroute_ms` number produced by a real simulated drop (not a hand-set value).
- **Cite:** WMEWMA SenSys 2003 (doi:10.1145/958491.958512); ETX MobiCom 2003; BFD RFC 5880.
- **Effort:** ~2 days. **Risk:** Medium (self-heal instrumentation touches the daemon loop;
  keep it `-sim`, no hardware).

---

## 7. Boundary — what this wave cannot / did not do

- **No hand-Rust fixes.** Every finding is a prescription to edit `.t27` specs and regenerate.
  Where the live module (`discovery.rs`, `daemon.rs`) has no spec, the first prescribed step is to
  *author the spec*, not patch the Rust.
- **Did not fix `main`.** `main` is red (build.rs); repair is owned by unmerged PRs #60/#59.
- **No hardware.** Nothing flashed, ordered, or measured; all PHY/AD9361/GPS items remain `-hw`
  (issue #8). No board/test/procurement counts invented.
- **Draft PR only, never merged, never pushed to `main`** — per `docs/AUTONOMOUS.md`.
- **Did not touch the crypto handshake** (owner-tracked, #63/#65) or re-report wave #59/#67 items.
- **Did not silently edit `docs/archive/STRENGTHEN.md`** — this wave *adds* a dated report; the
  backlog owner curates.

---

`phi^2 + phi^-2 = 3`
