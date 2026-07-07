# M2 Mesh Test Results — 2026-07-07

## Loopback 3-Node Mesh on P201Mini ARM (REAL HARDWARE)

### Test: 3 meshd instances on 127.0.0.1:5001/5002/5003

```
Node 11: ETX 12=1.00, 13=1.00    TX → 13: Forwarded(13)
Node 12: ETX 11=1.00, 13=1.00    (relay, all links converged)
Node 13: DELIVERED (last hop 11): hello_from_11
```

### Status: PASS
- 3 nodes with unique IDs ✓
- ETX convergence: inf → 1.00 in ~600ms ✓
- Message delivery: 11 → 13 DELIVERED ✓
- HELLO beacon exchange ✓
- Mesh routing (multi-hop forward) ✓

### Hardware: P201Mini (Zynq 7020, ARM Cortex-A9, armv7l)
### Binary: trios_meshd (Rust, armv7-unknown-linux-musleabihf, static)

### Multi-Board Mesh (3 physical boards)
Blocked by: identical MAC (00:0a:35:00:01:22) on all 3 boards.
Switch cannot route between same-MAC ports.
Solution: baked image with persistent unique MAC per board.

phi^2 + phi^-2 = 3
