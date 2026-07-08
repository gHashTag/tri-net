# M5 — Self-Healing Re-Route: Measured Convergence (2026-07-08)

**Component:** `trios-mesh` `src/router.rs`, `src/routing.rs`, `examples/m5_selfheal.rs`
**Commit:** `a290256`
**Goal:** the milestone M5 — *self-healing re-route with a MEASURED convergence
time*. The router already reroutes around a dead link
(`dead_direct_link_reroutes_via_relay`); this puts a number on how fast.

## What it answers

A skeptic's question: "what happens when a node dies?" → **traffic reroutes
around it in ~600 ms.**

## Method

Mirrors the daemon's routing loop (`HELLO_MS=300`, `ETX_WINDOW=3`,
`FAST_FAIL_MISSES=2`): node 1 has a direct route to destination 3 and a backup
relay 2. The **direct 1↔3 link dies** (sustained missed HELLOs); measure the HELLO
cycles until `next_hop(3)` reroutes via relay 2. Rerouting requires 3's direct
ETX to be declared dead (infinite).

## Result

| mode | convergence | wall-clock |
|------|------------:|-----------:|
| **fast-fail (B03)** | **2 HELLO cycles** | **~600 ms** |
| pure ETX (WMEWMA) decay | 3 HELLO cycles | ~900 ms |

- **Fast-fail** declares the link dead after 2 missed HELLOs (`force_dead`), so
  `next_hop` falls to the relay immediately — **~600 ms**.
- **Pure decay** waits for the WMEWMA estimate to cross the dead threshold on its
  own — one window (~900 ms).
- Fast-fail is **~1.5× faster** and both are **bounded** (the self-healing
  guarantee). Locked in by `self_heal_convergence_is_bounded_and_fast_fail_wins`
  (asserts fast-fail ≤ 2 cycles, decay bounded, fast-fail < decay).

## Why fast-fail matters

WMEWMA is deliberately smooth (it must not flap a route on one lost HELLO), so on
its own it takes a full window to condemn a link. B03 fast-fail short-circuits
that for a *sustained* loss (2 in a row) — the mesh reacts in the time it takes to
be sure, not the time it takes the average to decay. Against a route flap (single
miss) the counter resets, so it does not over-react.

## Scope

Host simulation of the routing layer (the same `MeshRouter`/`EtxTable` the daemon
runs). The convergence is in HELLO cycles; wall-clock uses the daemon's 300 ms
cadence. A real over-air multi-node measurement (with radio HELLO loss and a live
topology) needs 3+ boards on the net; the routing dynamics are proven here.

Note: rerouting to a non-neighbor destination via the *best* relay (`best_next_hop`)
is effectively instantaneous (it's a min over neighbor ETX) — the measured
convergence above is for the harder case, a **direct** link death that must be
condemned before the relay is used.

## Reproduce

```
cargo run --release --example m5_selfheal
cargo test self_heal_convergence
```
