# CSMA Mesh: All Three Nodes + Board 12 Internet Over Radio (2026-07-08)

Status: PASS. The full three-node radio mesh converges and the
previously-marginal node (board 12) fetches the internet over the air.
This closes the "board 12 never stays in the mesh" problem from
RADIO_MESH_RESULTS.md.

## Result (2425 MHz, CSMA + relay fix)

```
node 11 (gateway): { 12=1.48-2.68, 13=1.00-1.14 }
node 12 (board 12): { 11=1.83-3.10, 13=1.00-1.03 }   floor 34.3
node 13 (relay):    { 11=1.00-1.33, 12=1.00-1.07 }   -- sees BOTH solid
board 12: INTERNET-VIA-RADIO-MESH: 182.232.227.12      -- fetched over radio
gateway 11: gwfetch:1
```

All three links converge; board 12 reaches the internet through the mesh.

## What it took (four changes, all committed)

1. **CSMA/CA listen-before-talk.** RX stamps a shared atomic "air busy"
   clock whenever it senses energy (at a lower threshold than frame
   detection); TX runs a randomized backoff that freezes while busy and
   counts down while idle, with a hard slot cap so it never starves. This
   removes the 3-node half-duplex collisions that previously collapsed
   even the good 11<->13 link when board 12 joined. Reviewed for
   deadlock / DMA-underrun / starvation — all clear.

2. **TRIOS_FREQ (startup band) + live channel scan.** A direct per-node
   noise sweep found strong 2.4 GHz interferers that HOP across the band
   over minutes: 2450 clean then jammed (169), 2465 clean then jammed
   (44), 2480 clean then jammed (51), 2425 clean. Whichever node sits on
   the jammed channel goes deaf (its noise floor jumps 20 -> 130+ and its
   detection threshold rises above the incoming signal). So the operating
   channel must be chosen from a CURRENT scan that is clean at ALL three
   nodes. TRIOS_FREQ makes each node calibrate on that band at startup
   (retuning after a restart raced the default and was unreliable).

3. **FETCH retry.** Over a lossy, no-FEC, half-duplex link a single
   request/reply pair is easily dropped. The requester re-asks up to 8x
   (every 4 s) until the reply lands; an AtomicBool stops it on success.

4. **Multi-hop relay crypto fix (the decisive one).** Crypto is hop-by-hop
   (each frame is opened under the *receiving link's* session), but on a
   broadcast radio the receiver cannot read the transmitter off the air —
   the plaintext header carries the END-TO-END src, not the previous hop.
   The radio RX used the header src to pick the session, so a relayed
   frame (gateway -> relay 13 -> board 12) was opened under the origin's
   session (11) instead of the relay's (13) and always failed AEAD — the
   internet reply could never reach board 12 via the relay. Fix: the RX
   now tries each neighbor session; a wrong one fails the AEAD open with
   no state change (open() advances the replay window only AFTER a
   successful decrypt), so the first that opens is the true sender.

## Per-node notes

- Board 12 needs `TRIOS_TXGAIN=-12`: poor TX/RX antenna isolation means it
  hears its own transmit loudly and, at full power, jams its own reception.
- Node 13 is the natural relay hub (hears both peers solidly at 2425).
- Board 12<->11 direct is marginal; board 12 reaches the gateway both
  directly (when up) and via the 13 relay (now that relayed frames
  validate).

## Honest limits / next

- No FEC on the modem: marginal links still lose frames; the fetch retry
  masks it for request/reply but bulk data would need forward error
  correction.
- Channel selection is manual (pick a clean-for-all channel from a scan).
  An auto-scan-at-startup in the daemon would make this hands-off.
- Single-node restart desyncs the AEAD replay counter vs long-running
  peers (they reject the restarted node's frames until all rekey) — so
  restart the whole mesh together, or add session re-handshake on the air.
- CSMA sense latency (~4-6 ms from the DMA/read pipeline) exceeds the 3 ms
  guard, so it reduces but does not perfectly prevent collisions; it was
  sufficient here on a clean channel.
