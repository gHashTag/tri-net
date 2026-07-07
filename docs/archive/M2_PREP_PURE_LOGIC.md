# M2-Prep Pure-Logic Tests

Anchor: phi^2 + phi^-2 = 3

## Context

M1 is scientifically closed on the Zynq-7020 Mini platform. See
[smoke/M1_SCIENTIFIC_CLOSURE_2026-07-04.md](../smoke/M1_SCIENTIFIC_CLOSURE_2026-07-04.md).

M2 real-network stand-up is blocked on the image-bake milestone
([docs/IMAGE_BAKE_MILESTONE.md](IMAGE_BAKE_MILESTONE.md)) because:

- stock rootfs is `ramfs`, so `/etc/network/interfaces` wipes on cold-boot
- all three boards ship with identical MAC `00:0a:35:00:01:22` (Xilinx OUI)
- runtime MAC-spoof + `ethtool` fixes were falsified on 2026-07-04 (5/5 paths fail)

Until baked images exist, we cannot exercise a real 3-board mesh. But the
pure-logic surface can still be tightened without any radios, TUN devices, or
UDP sockets. That is what this PR does.

## Scope

`tests/m2_routing_pure_logic.rs` (25 new host tests, all `-sim`):

- **TUN allocation math** (`mesh_ip` / `node_of` over `10.42.0.0/24`) — full
  1..=254 roundtrip, rejection of network/broadcast/wrong subnets, wrap
  behaviour on out-of-range `NodeId` values.
- **Wire header boundaries** — all `FrameKind` roundtrips, rejection of every
  unknown kind byte, truncation at every offset, TTL extremes, `Header::LEN`
  pin.
- **HELLO wire boundaries** — 33-byte empty floor, linear length scaling, max
  `n=255` roundtrip, silent truncation of oversized `heard[]`, per-byte
  truncation rejection across the MAC region, forged oversized length prefix
  rejection, `reports_hearing` semantics.
- **ETX ordering / arithmetic** — deterministic pick under identical ETX,
  `compute_path_etx` overflow saturation to `+inf`, NaN/inf advertised
  rejection, `force_dead` idempotence on unknown neighbors, `neighbors()`
  sorted-by-id contract.
- **Cross-module invariant** — HELLO body is strictly longer than
  `Header::LEN`, so the two shapes cannot be silently confused.

## What this PR is NOT

- Not a M1 continuation. Board-1 was validated on 2026-07-04
  (sha256 `a17e88e6...`, RC=0); boards 2/3 are byte-identical replicas and
  need no fresh datapoints.
- Not a M2 real-network change. No `daemon.rs`, no UDP, no `/dev/net/tun`, no
  radio bring-up. All of that is downstream of image-bake.
- Not a routing behaviour change. Every test pins **observed** behaviour of
  the current code. Where the current behaviour is arguably wrong (see
  `learn_route_first_infinite_metric_is_currently_accepted`), the test
  explicitly labels it as a `-sim` observation with a plan-of-record note,
  not a spec claim. Fixing it is its own PR post image-bake.

## Findings surfaced by writing these tests

1. **`is_feasible` accepts a `+inf` first metric.** `routing.rs::is_feasible`
   short-circuits to `true` when no prior route exists, so
   `learn_route(dst, nh, f32::INFINITY)` currently succeeds for a virgin
   destination. Any finite advertisement instantly shadows it, so the impact
   is bounded, but the check is asymmetric and worth revisiting.
2. **`Hello::to_bytes` silently truncates `heard[]` at 255.** This is
   intentional (the length prefix is `u8`), but it means a caller cannot tell
   from the return value that data was dropped. Consider returning
   `Result<Vec<u8>, HelloTooLarge>` in a future revision.

## How to run

```bash
cargo test --test m2_routing_pure_logic
cargo test --lib
```

Local run on 2026-07-04:

- `cargo test --test m2_routing_pure_logic`: 25 passed, 0 failed, 0 ignored.
- `cargo test --lib`: 99 passed, 0 failed, 0 ignored.

## Honesty ledger

- All tests are host-only. Nothing here has been executed on the Zynq Mini.
- Every test carries a `-sim` note directly or through the file-level module
  comment.
- No metrics (throughput, PPS, RTT, PDR) are claimed anywhere in this PR.
  Those numbers land only after image-bake plus a real 3-board smoke.
- No Trinity/silicon claims. The rule "No chip, no TRI. Period." holds.
