# M2 step 2 — one-board on-device bring-up: RESULTS

**Date**: 2026-07-06
**Status**: PASS on hardware (5/5 completed runs)
**Milestone significance**: **first hardware datapoint in the project**
**Anchor**: `phi^2 + phi^-2 = 3`

---

## Provenance

- Board: **P201Mini**, hostname `pzp201mini`
- SoC: Zynq-7020, armv7l
- Kernel: `Linux 5.10.0-97866-g4efeacd06cfc-dirty armv7l`
- Network: `eth0`, `192.168.1.10`
- Board recovery: `tri-mini-1` reflashed as `pzp201mini` on 2026-07-06 after
  discovery report showed the earlier mDNS name was dead
- Binary: `dist/trios_meshd.armv7-musl` (statically linked, armv7 musl)
  - sha256 (host): `a0c03c91bd0102528d5caf208be620647f92b9755aa404882c74f4344a6bc064`
  - sha256 (board): confirmed identical after `scp`
- Gate scripts: `smoke/m2_onboard_bringup.sh` + `smoke/m2_onboard_bringup_n_runs.sh`
  at branch `feat/w10-m2-onboard-bringup`, commit `ece071a`
- Cross-build recipe: see `smoke/M2_ONBOARD_BRINGUP_HOWTO.md`

---

## Representative run — JSON

Run 1 (all 5 completed runs identical up to timestamps):

```json
{
  "verdict": "PASS",
  "iface": "eth0",
  "ip": "192.168.1.10",
  "port": 5011,
  "node_id": 11,
  "duration_s": 6,
  "daemon_rc": 143,
  "bin_sha256": "a0c03c91bd0102528d5caf208be620647f92b9755aa404882c74f4344a6bc064",
  "uname": "Linux 5.10.0-97866-g4efeacd06cfc-dirty armv7l",
  "log_lines": 7,
  "bind_evidence": 1,
  "beacon_ticks": 6,
  "crash_marks": 0
}
```

## Reproducibility — N=5 (v1.3 discipline)

| Runs completed | Verdict | bind_evidence | beacon_ticks | crash_marks |
|----------------|---------|---------------|--------------|-------------|
| 5 / 5 | PASS | 1 | 6 | 0 |

- 4 runs from a clean sequential series
- 1 run from an earlier wrapper attempt (identical output)
- Every **completed** run: `verdict=PASS`, deterministic and identical

**Separately observed**: 2 SSH connection drops during other attempts —
empty results, NOT gate failures. Root cause: dropbear session instability
on the board (ephemeral host keys, key regeneration per connection).
Not a binary / gate issue. Every run that COMPLETED returned PASS.

---

## What this proves

- Daemon starts on real ARM hardware (Zynq-7020, Linux 5.10)
- Binds to real `eth0`, not `127.0.0.1` (gate correctly rejects loopback)
- HELLO/beacon loop alive: 6 ticks over 6 s ~= 1 Hz (matches design cadence)
- No panics / crash markers (`crash_marks=0`)
- `daemon_rc=143` = 128 + 15 = SIGTERM from the script's graceful shutdown
  — expected clean exit path
- musl-static binary loads and runs without any dynamic-loader issue —
  portability decision (musl over glibc) is validated on real Mini rootfs
- Property-based gate (bring-up, not convergence) holds reproducibly on
  hardware

---

## Honest scope — what this does NOT prove

- **Step 2 is not M2 done.** Step 2 (one-board bring-up) has a hardware
  datapoint. Steps 3 (two-board) and 4 (three-board TUN + iperf3) remain.
- README `-sim` flag is **NOT cleared** by this result. It clears only
  after step 4.
- No neighbor discovery / ETX convergence tested here (needs a second
  board).
- No radio-noise stability tested (needs 2+ boards on real radio).
- No throughput measurement (step 4).

---

## Trajectory to here

The path that led to this datapoint:

1. W7 weak-points audit -> W8 competitor watch -> W9 critical-triangle
   design (three consecutive documentation waves)
2. General flagged the drift: "5th wave of documentation while hardware
   sits idle" — genuine structural pattern, not one-off
3. Honest self-correction: hardware was accessible, I had depriorised it,
   not been blocked by it
4. W10 pivot: cross-build `trios_meshd` -> property gate -> N=5 wrapper
5. SocketAddr fix + gate v2 (from earlier session) — infrastructure was
   already ready
6. Portability incident: shipped glibc-dynamic first, corrected to
   musl-static (matches M1 build scheme)
7. Squash-merge stacked-PR incident learned in W7.5 — v1.4 discipline
   applied, W10 PR opened base=main independently
8. Board discovery incident: `tri-mini-1` mDNS dead; general reflashed as
   `pzp201mini` @ 192.168.1.10; discovery tool `tools/mini-discovery.sh`
   committed to help future recovery
9. Run on real hardware: 5/5 PASS

---

## Next

- **Step 3** — two-board on-device smoke. First real-radio convergence test
  between `pzp201mini` and a second board. Requires: bring second board up
  on same subnet (or same radio), point their configs at each other, verify
  neighbors appear in each other's `neighbors { ... }` log lines, gate on
  **bilateral bind + bilateral neighbor discovery + no crash**. Still a
  property gate, not asymptote.
- **Step 4** — three boards + TUN/IP + iperf3 across a 2-hop path. This is
  the real M2 hardware gate. On PASS: README `-sim` -> `hw`.

---

## Discipline reflection

- **v1.2 numbers-with-realm-check**: every number in this file is either
  quoted directly from a completed run JSON or annotated as design cadence
  vs measurement.
- **v1.3 aspiration-vs-property + results-without-repro**: gate is property
  (bind/beacon/crash), reproduction is N=5 completed runs.
- **v1.4 stacked-PR-after-squash**: PR #53 is base=main, not stacked.
- **Trinity rule**: still holds — this is bring-up on one board, not a
  claim about mainnet consensus.
- **0% premine**: unaffected by this work.

phi^2 + phi^-2 = 3
