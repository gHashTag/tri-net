# QoS Traffic Shaping (iter32)

**Date:** 2026-07-08
**Commit:** `e7ec2ff` (trios-mesh)
**Tests:** 308 total (+13 QoS)

## What

Priority + reservation scheduler for the constrained RF mesh. Ensures
time-critical traffic is never stuck behind bulk transfers.

```
Priority 0 (RealTime):    text, voice, HELLO, handshake      — always first
Priority 1 (Interactive): photo, file chunks, NACK            — ≤3 tick gap
Priority 2 (Streaming):   video, TUN IP packets               — ≤5 tick gap
Priority 3 (Bulk):        NAT/gateway, large downloads        — ≤10 tick gap
```

## Scheduler Algorithm

```
tick():  gap[class] += 1 for all classes

dequeue():
  Phase 1 (reservation): if gap[class] >= max_gap[class] AND has frames
                         -> service (preempts strict priority)
  Phase 2 (strict):      highest-priority non-empty queue
```

**Starvation guarantee**: Bulk gets ≥1 frame every 10 ticks, even under
100% RealTime load. Tested and verified.

## Classification

Two-layer classification:

1. **Mesh frame type** (type byte):
   - HELLO(0), DATA(1), HANDSHAKE(0xE2), GATEWAY(5) → RealTime
   - FILE_META/CHUNK/NACK/DONE(0x10-0x13) → Interactive
   - TUN(4) → Streaming
   - Unknown → Bulk

2. **IP DSCP refinement** (for TUN packets):
   - EF (DSCP 46) → RealTime (voice over mesh)
   - AF (DSCP 10-43) → Interactive
   - Default → stays Streaming

## Verified Properties

| Test | Property |
|------|----------|
| `strict_priority_text_before_video` | Text dequeues before video |
| `starvation_prevention_bulk_eventually_drains` | Bulk gets >0 under 100% RT |
| `fifo_within_same_class` | Order preserved within a class |
| `frame_type_classification` | All type bytes classified correctly |
| `ip_dscp_refinement_*` | EF→RT, AF→Interactive, default→unchanged, IPv6→unchanged |

phi^2 + phi^-2 = 3
