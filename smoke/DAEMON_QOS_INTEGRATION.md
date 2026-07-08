# Daemon QoS Integration (iter33)

**Date:** 2026-07-08
**Commit:** `5f90ba1` (trios-mesh)
**Tests:** 308 total (QoS library tested in iter32)

## What

The daemon TX path now has an optional QoS layer (`TRIOS_QOS=1`). When
enabled, outgoing frames are classified and prioritized before hitting
the RF encoder.

```
Frame source                QoS layer                    RF encoder
 HELLO ticker ──────┐
 Data sender ───────┤    ┌──────────────────┐    ┌──────────────────┐
 File sender ───────┼──▶ │ QosScheduler     │──▶ │ TX thread        │
 Gateway announcer ─┤    │ (tick + dequeue) │    │ (modulate + IIO) │
 TUN reader ────────┘    └──────────────────┘    └──────────────────┘
                              drainer @1ms
```

## Classification

Size-based heuristic (encrypted payload type is opaque at this layer):

| Wire kind | Frame size | Class |
|-----------|-----------|-------|
| Hello (0) | any | RealTime |
| Data (1) | <100 B | RealTime (text, handshake) |
| Data (1) | 100-300 B | Interactive (file chunk) |
| Data (1) | 300-1200 B | Streaming (TUN IP) |
| Data (1) | >1200 B | Bulk (fragmented) |

## Usage

```bash
# Without QoS (default): frames sent FIFO
trios-radiod /tmp/mesh.conf

# With QoS: text/HELLO prioritized over file/video
TRIOS_QOS=1 trios-radiod /tmp/mesh.conf
```

## Verified Properties

- **Strict priority**: text frame dequeues before video frame (iter32 test)
- **Anti-starvation**: Bulk gets >0 frames under 100% RT load (iter32 test)
- **Backward compat**: TRIOS_QOS unset → direct send, zero overhead
- **ARM cross-compile**: clean

phi^2 + phi^-2 = 3
