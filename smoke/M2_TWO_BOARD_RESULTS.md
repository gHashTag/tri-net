# M2 Real Mesh on Physical Boards — Results (2026-07-08)

Status: PASS, both milestones. Two-board real mesh AND three-board convergence,
previously both blocked ("need stable SD boot" / "need 3 stable boards") in
docs/FULL_PROJECT_CONTEXT.md section 6.

## Three-board convergence (full triangle 11-12-13)

All three physical boards, full-mesh peer config, UDP port 5000:

```
node 11 (.11): neighbors { 12=1.00, 13=1.00 }   TX test -> 13: Forwarded(13)
node 12 (.12): converged both links (343 HELLO rounds logged)
node 13 (.13): neighbors { 11=1.00, 12=1.00 }   DELIVERED (last hop 11): hello_from_11
```

ETX converged 4.00 -> 1.14 -> 1.00 on all six directional links in under 1 s.
M1 crypto smoke: PASS 3/3 boards (RC=0 on .11, .12, .13; identical md5 binaries).
Board 1 ("dead" per prior docs) booted with its repaired SD identity
(ethaddr 02:00:00:00:00:01, kernel ip=192.168.1.11) after one cold power-cycle.

## Result

```
Node 12 (192.168.1.12): ETX 13=1.17 -> 1.02 -> 1.00 (< 1 s)
Node 12: TX test -> 13: Forwarded(13)
Node 13 (192.168.1.13): ETX 12=1.34 -> 1.04 -> 1.00
Node 13: DELIVERED (last hop 12): hello_from_12
```

Per-hop ChaCha20-Poly1305, HELLO/ETX beacons at 300 ms, UDP port 5000.
Binaries: `target/armv7-unknown-linux-musleabihf/release/trios_meshd`
(md5 fc6ebf6d49f132ce6d12e30be7c093f2), deployed via ssh-cat, md5-verified.
M1 crypto smoke also re-run on BOTH boards this session: PASS (RC=0) on .12 and .13.

## Root cause of the "board boots briefly then dies" mystery

The boards never died. It was a NETWORK IDENTITY COLLISION:
multiple boards live on the wire at the factory IP 192.168.1.10, and two SD
cards had both been written with `ethaddr=02:00:00:00:00:02` (duplicate MAC ->
switch MAC-table flapping). ARP entries flapped between boards and sessions
collapsed. Diagnosed and fixed over the UART consoles with no reflashing.

## Blockers closed this session

1. "No UART output": FT2232H channel B is the UART (Digilent convention;
   FULL_PROJECT_CONTEXT section 13 has A/B swapped). 115200 8N1.
   macOS devices: `/dev/cu.usbserial-2102038592891`, `-4`, `-6`.
   Login `root` / `analog`. Holding channel A open does not block channel B.
2. "Persistent IP": append ONE line to the stock vendor uEnv.txt:
   `bootargs=console=ttyPS0,115200n8 root=/dev/ram rw earlyprintk ip=192.168.1.1N::192.168.1.1:255.255.255.0::eth0:off`
   Stock `sdboot` passes `${bootargs}` (imported from uEnv.txt) to bootm; the
   kernel brings up eth0 with the per-board static IP as primary.
   No `uenvcmd`, no `boardargs` (those cause the known infinite recursion).
3. "Board 1 dead": FALSE. JTAG/DAP damage does not affect SD boot; board 1
   boots Linux and answers on its console. Its SD carried the duplicate
   ethaddr 02; fixed to `ethaddr=02:00:00:00:00:01` + bootargs ip=.11 via
   console. Its eth0 was downed to stop MAC flapping; it needs one cold
   power-cycle to come back as board 1 at 192.168.1.11.

## Board map (console port -> identity)

| FTDI ch-B device                 | ethaddr (uEnv)      | IP after boot |
|----------------------------------|---------------------|---------------|
| /dev/cu.usbserial-2102038592891  | 02:00:00:00:00:01   | 192.168.1.11 (after cold power-cycle) |
| /dev/cu.usbserial-4              | 02:00:00:00:00:02   | 192.168.1.12 |
| /dev/cu.usbserial-6              | 02:00:00:00:00:03   | 192.168.1.13 |

## Runtime IP note (busybox/kernel gotcha)

`ip addr del 192.168.1.10/24 dev eth0` on the PRIMARY address also flushes all
secondaries on the same subnet (`promote_secondaries=0`). Delete .10 first,
then `ip addr add 192.168.1.1N/24 dev eth0`.

## Next

- Cold power-cycle board 1 -> expect it at .11 -> run 3-board convergence.
- Commit the proven uEnv recipe into tools/board-configs (see pending task).
