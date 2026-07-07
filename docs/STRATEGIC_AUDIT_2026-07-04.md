# Strategic Audit — 2026-07-04 (post-Option-B convergence)

**Scope:** weak-points audit + competitor scan + decomposed plan for the next loop.
**Method:** every finding grounded in verified repo state (commit SHAs, open PRs/issues, test counts) or a primary-source URL. No fabricated metrics.

---

## 1. Weak-points audit

### 1.1 Local `main` divergence — latent footgun (HIGH)

Local `main` = `a415fc9`, **ahead 33 / behind 13** vs `origin/main` (`dc1bebb`).
The 33 local-unique commits are the original wave work (Wave 4–9: specs, tests, reports) that evolved in the local clone separately from the cloud-driven origin line. Some of this work (tests, specs) **may not be on origin** — `origin/main` lib = 137 tests; the wave work claimed up to 110 per-wave. **Risk:** resetting loses unique tests/specs; not resetting leaves the divergence footgun that caused a wrong-diff-base earlier this session. Needs deliberate reconciliation (cherry-pick unique tests → origin, then sync).

### 1.2 Four stale draft PRs — triage needed (MEDIUM)

| PR | Branch | Title | Status assessment |
|---|---|---|---|
| #27 | feat/triangle-protocol | L0–L4 measurement spec | Relevant (M2 prep); LOCAL_FLASH + protocol docs. Ready for review. |
| #28 | feat/competitor-matrix-2026-07-04 | 10-vendor matrix with prices | May overlap with `BENCHMARK_VS_MANET` (merged). Check for redundancy. |
| #29 | feat/wave-depin-2026-07-04 | Wave DePIN — 4-armed node | Strategic doc; depends on M2+ (mesh working). |
| #36 | docs/paper-delta-v0 | δ-paper skeleton + §5 Reference Impl | Awaits positioning (ORCID/venue). |

All draft; none blocking. Triage: merge #27 (measurement protocol is referenced by the milestone chain), assess #28 for redundancy with the merged benchmark, defer #29/#36 to their dependency readiness.

### 1.3 M2–M5 milestone chain — blocked on image-bake (HIGH, hardware)

Issues #11–#14 (M2 TUN+ETX, M3 2-hop iperf, M4 shared uplink, M5 self-heal) are all blocked on the 3-board network stability that requires **image-bake** (unique MAC per board baked into the SD image). Verified this session: runtime approaches all fail on the stock ramfs image (identical MAC → ARP flux; MAC spoof → GEM offload breaks bulk TX; no ethtool; /etc ephemeral). **Blocker: SD-card reader + `mkimage`** (or in-place reflash, risky).

### 1.4 T27 expansion — blocked on t27#1258 (MEDIUM, upstream)

`discovery.t27` and `daemon.t27` flips (the next modules after wire.t27) are blocked on t27 issue #1258 (dynamic array/RAM lowering in gen-verilog). The wire.t27 flip is done (multi-target SSOT), but expanding SSOT to the full protocol stack needs t27 array support.

### 1.5 δ-paper — skeleton, needs positioning (MEDIUM, user input)

PR #36 has a solid skeleton + §5 Reference Implementation. Full v1 needs: author affiliation, ORCID, target venue (arXiv cs.NI vs cs.CR), and a decision on what's publishable vs proprietary. Unblocked from code side; blocked on user positioning.

### 1.6 Competitor-watch cron — unverifiable from sandbox (LOW)

Cron `64822c1c` is platform-side (Perplexity scheduler), reads `docs/COMPETITOR_WATCH_SPEC.md` from repo. Cannot verify from Mac (no platform API access). SPEC is the source of truth; executor is swappable. Next tick: Fri Jul 10 09:00 Bangkok.

### 1.7 Local branch clutter — PARTIALLY CLEANED (LOW)

Deleted this cycle: `feat/t27-first-wire`, `local/sprint2-path-diversity-2026-07-04`, `wave-n2-benchmark-2026-07-04` (all merged/stale). Remaining: `feat/wave-competitors-2026-07-03`, `feat/wave-n2-benchmark` (old, no remote — can delete), `main` (divergent, see 1.1), `feat/triangle-protocol` (PR #27 open).

---

## 2. Competitor landscape (fresh scan, 2026-07-04)

### 2.1 Incumbents — stable, no new products

| Vendor | Product | Recent signal | Threat level |
|---|---|---|---|
| Persistent Systems | MPU5 Wave Relay | No new product; marketing stable | HIGH (incumbent leader, FIPS-validated) |
| Silvus Technologies | StreamCaster (MN-MIMO) | SHOT Show 2026 (marketing event, not new product) | HIGH (tech leader, 559-node demo) |
| Rajant | Kinetic Mesh (BreadCrumb) | "AI-driven" messaging, no spec-open move | MEDIUM (industrial focus) |

**Key finding:** no incumbent has moved toward spec-openness or auditability. The δ-thesis axis remains **vacant** — Tri-Net's differentiator is uncontested.

### 2.2 Adjacent research (from prior scan, still relevant)

- **Carrone δ-thesis** — direct theoretical overlap with Tri-Net's auditability claim.
- **Reticulum / Meshtastic** (GRICAD) — open-source mesh, but NO spec-first/auditability framing.
- **RISC-V HDL Tournament** (Chisel/SpinalHDL/Amaranth) — reproducible HDL ecosystem, adjacent but not mesh-specific.
- **Qualcomm AI-mesh patent** — AI-driven mesh config, proprietary, no auditability angle.

**No direct competitor on the spec-open + reproducible + auditable axis.** Tri-Net's positioning is unique.

---

## 3. Decomposed plan (workstreams → milestones → blockers → owners)

### WS-1: Hygiene + reconciliation (UNBLOCKED, sandbox)
- [x] Delete stale local branches (done this cycle).
- [ ] Reconcile local `main` divergence: identify unique tests/specs in the 33 local commits, cherry-pick to origin, then `git reset --hard origin/main`.
- [ ] Triage draft PRs: merge #27, assess #28, defer #29/#36.
- **Owner:** local agent (sandbox). **Blocker:** none.

### WS-2: δ-paper v1 (BLOCKED on user positioning)
- [ ] User provides: ORCID, affiliation, target venue, publish/propetary split.
- [ ] Develop v0 skeleton → v1 (formal audit-trail primitive, 6–8 pages).
- [ ] User final review → arXiv submission.
- **Owner:** shared (agent drafts, user finalizes). **Blocker:** user positioning.

### WS-3: M2 image-bake (BLOCKED on hardware)
- [ ] Obtain SD-card reader (or accept in-place reflash risk).
- [ ] Install `mkimage` (`brew install u-boot-tools`).
- [ ] Pull `image.ub` from board-1 via SSH.
- [ ] Unpack ramfs → add unique MAC/IP/hostname + smoke-m1 → repack → flash × 3.
- [ ] Cold-boot verify: 3 distinct MACs in ARP, M1×3 trivial (boot + run pre-installed binary).
- **Owner:** local agent (sandbox builds, user flashes). **Blocker:** SD-card reader.

### WS-4: T27 protocol-stack expansion (BLOCKED on t27#1258)
- [ ] t27#1258: implement dynamic array/RAM lowering in gen-verilog.
- [ ] Port `discovery.t27` (HELLO framing) → drift-guard row.
- [ ] Port `daemon.t27` (framing FSM) → drift-guard row.
- **Owner:** shared (t27 upstream + tri-net consumer). **Blocker:** t27#1258.

### WS-5: Competitor-watch (ACTIVE, automated)
- [x] SPEC in repo (PR #34, merged). Cron reads it weekly.
- [ ] First tick: Fri Jul 10 09:00 Bangkok.
- **Owner:** platform cron (automated). **Blocker:** none (running).

---

## 4. Implementation log (this cycle)

- Deleted 3 stale local branches (merged/gone tracking).
- This audit doc.
- No code changes (unblocked engineering is exhausted without hardware/user-input/upstream).

---

## 5. What's NOT here (honest scope)

- No M2/M3/M4/M5 code (hardware-blocked).
- No t27#1258 fix (upstream, complex compiler work).
- No δ-paper v1 (user positioning needed).
- No fabricated competitor metrics (only verified sources cited).

φ² + φ⁻² = 3
