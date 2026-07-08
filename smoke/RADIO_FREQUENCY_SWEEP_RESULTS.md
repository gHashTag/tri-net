# Radio Mesh: Multi-Frequency Sweep + Stable Wire-Free Operation (2026-07-08)

Status: PASS (stable backbone + wire-free internet). Boards 2 and 3 both
physically OFF Ethernet; only board 1 wired as the internet gateway. Boards
12 and 13 driven purely over their UART consoles. Frequency retuned at
runtime via sysfs under the running daemon (the noise-floor tracker adapts
in ~1 ms), so no rebuild/redeploy was needed to test each band.

## Frequency sweep (AD9361 tuned across the band; 2.4 GHz whip antennas)

Retuned all three nodes' RX+TX LO together; measured each link's ETX
(finite = converged, `inf` = down) over a ~30 s dwell. Board 11 (gateway)
read reliably over SSH; boards 12/13 over console.

| LO freq  | 11<->13 backbone | 12<->13 relay | 11<->12 direct | verdict |
|----------|------------------|---------------|----------------|---------|
| 915 MHz  | inf (down)       | 1.07 (up)     | inf            | backbone lost (11 RX mismatch) |
| 1575 MHz | inf (down)       | -             | inf            | worst — 11 deaf |
| 2400 MHz | 1.0-2.0 (up)     | flapping      | inf            | backbone solid, board12 marginal |
| **2450 MHz** | **1.0-1.3 (up)** | **2.14 (up)** | **occasional (1.9-3.5)** | **best — all links present** |
| 5800 MHz | 1.0-2.0 (up)     | inf (down)    | inf            | backbone solid, board12 lost |

Key finding: links are strongly frequency-dependent (antenna match +
multipath + per-band interference differ per node). No single band makes
every link solid at once, but **2450 MHz is the best channel** — the
11<->13 backbone stays solid AND board 12 joins (via the 13 relay, and
board 11 even hears board 12 directly at times). 2.4 GHz variants clearly
beat sub-GHz and 5.8 GHz here because the antennas are 2.4 GHz whips.

## Stable wire-free operation (default 2.4 GHz, reliable)

Runtime console retune after a daemon RESTART proved racy (the restart
resets the LO to the 2.4 GHz default and the post-restart console retune
is unreliable). The dependable configuration is therefore the **2.4 GHz
default with no retune** — every node boots radiod straight onto the same
band. Result, reproducible:

```
gateway 11: gateway fetched "182.232.227.12" -> reply to 13: Forwarded(13)
board 11 neighbors: { 12=inf/2.69, 13=1.00-1.14 }   (backbone solid; 12 direct at times)
board 13 (wire-free): INTERNET-VIA-RADIO-MESH count = 1
```

Board 13 — fully wire-free — requested the internet over the air, the
gateway fetched it and the reply came back over the air. This is stable
and repeatable across the whole session.

## Honest state of the third node (board 12)

Board 12 has poorer TX/RX antenna isolation (documented: it hears its own
transmit loudly). With `TRIOS_TXGAIN=-12` its self-interference drops and
it converges to the relay (board 13) and is sometimes heard directly by
the gateway. But simultaneous rock-solid 3-node operation is not achieved
without medium-access control: three half-duplex transmitters on one
channel collide, and board 12 (the marginal node) drops in and out. 2450
MHz helps; CSMA listen-before-talk is the real fix and remains the next
milestone. A board-12 fetch reached the gateway earlier in the session
but is not reliable run-to-run.

## Operating recipe (wire-free, survives reboot)

Binaries baked to each board's SD (`/mnt/boot/bin/trios_radiod`); restore
after reboot with `mount /dev/mmcblk0p1 /mnt/boot && cp
/mnt/boot/bin/trios_radiod /tmp/ && chmod +x /tmp/trios_radiod`.

```
# gateway (has uplink):   TRIOS_GATEWAY=1 trios_radiod mesh.conf
# wire-free leaf:         TRIOS_FETCH=<gwid> trios_radiod mesh.conf
# poor-isolation node:    prefix TRIOS_TXGAIN=-12
# better channel:         echo 2450000000 > .../out_altvoltage{0_RX,1_TX}_LO_frequency
#                         (retune the RUNNING daemon; do not retune right after a restart)
```

## Next
- CSMA listen-before-talk -> stable simultaneous 3-node + M5 self-heal.
- TRIOS_FREQ env so a node calibrates on the target band at startup
  (removes the restart/retune race) — needs redeploy, so bundle with the
  next Ethernet-replug or SD-bake.
