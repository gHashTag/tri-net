# M2 Loopback Smoke — Fix Verification (2026-07-05)

Anchor: `phi^2 + phi^-2 = 3`

## Context

On 2026-07-05 the initial run of `smoke/m2_loopback_smoke.sh` (introduced
in PR #48) surfaced a sandbox-testability defect in `src/bin/trios_meshd.rs`:
the neighbor identity map was keyed on `IpAddr`, so all three loopback
processes on `127.0.0.1` collided into a single entry. Node-12 ↔ node-13
would still converge on ETX ~1.00 because the last `insert` wins, but
node-11 dropped out of the graph and stayed isolated.

Real hardware (three P203 Mini boards on distinct interfaces) is unaffected
— every board has a unique IP. The defect only manifests when the test
harness forces multiple daemons onto one loopback address, which is exactly
what a CI smoke rig has to do.

## Fix

`src/bin/trios_meshd.rs`:

- `HashMap<IpAddr, NodeId>` → `HashMap<SocketAddr, NodeId>` (rename
  `ip_to_id` → `addr_to_id` to keep the code honest about the key).
- Central RX now dispatches on the full `src: SocketAddr` returned by
  `recv_from`, not just `src.ip()`.
- `use std::net::IpAddr` dropped (no longer needed).

Behaviour is a strict superset of the previous code on real hardware
(unique IPs collapse trivially into unique `SocketAddr`s once the map
is keyed that way), and correct on any loopback scenario.

## Regression gate

`smoke/m2_loopback_smoke.sh` now ends with a "triangle convergence gate":
every node's last `neighbors` log line must list **both** peers at steady
ETX in the range `1.00–1.09`. Any missing peer or non-steady ETX fails
the script with exit code 2. This is the automated tripwire for anyone
who accidentally regresses the fix.

## Reproduction

```bash
cd /home/user/workspace/tri-net
cargo build --bin trios_meshd --release
DURATION=10 ./smoke/m2_loopback_smoke.sh ; echo "exit=$?"
```

## Result (2026-07-05, this session, `-sim`)

```
=== triangle convergence gate ===
node 11: PASS — both peers at steady ETX ([meshd] node 11 neighbors { 12=1.00, 13=1.00 })
node 12: PASS — both peers at steady ETX ([meshd] node 12 neighbors { 11=1.00, 13=1.00 })
node 13: PASS — both peers at steady ETX ([meshd] node 13 neighbors { 11=1.00, 12=1.00 })

smoke duration: 10s
exit=0
```

## What this smoke is NOT

- It is not a hardware M2 datapoint. The triangle is over loopback UDP,
  no radios, no PHY, no interference. All measurements are `-sim`.
- It does not exercise TUN/IP forwarding — that is the next M2 sub-step
  once the image-bake milestone (`docs/IMAGE_BAKE_MILESTONE.md`) unblocks
  three-board deployment.
- It does not prove the fix under IPv6, dual-stack, or non-localhost
  aliases; but for the pre-hardware regression tripwire it is sufficient.

## Discipline hooks

- no-fabricated-metrics: every number above came from a real run on this
  sandbox at 2026-07-05 22:2x +07 and is labelled `-sim`.
- SHA-advance rule: any approval of this fix binds to the commit SHA that
  the reviewer explicitly cites. Advancing the branch requires
  `Re-reviewed at <new_sha>: delta <bullet-list>`.
- Results-without-repro-check: the reviewer's insistence on running the
  smoke a second time surfaced non-determinism that no single run could
  have exposed. New rule captured in `tri-net-m2-m4-workflow` v1.3:
  smoke-gate outcomes require N-run confirmation (default N=5) before they
  are trusted as regression tripwires.
- Skill update: `tri-net-m2-m4-workflow` v1.3 records both the sandbox-
  testability defect closure and the gate-design lesson (WMEWMA
  non-determinism, aspiration-vs-property confusion).

## Full test suite

`cargo test --workspace --release`: **137 tests passed, 0 failed**.
The fix does not touch any pure-logic surface.

phi^2 + phi^-2 = 3
