# Radio Mesh: Internet Over The Air — Results (2026-07-08)

Status: PASS. The full mesh stack runs over the real radio with NO Ethernet
between nodes, and an Ethernet-less board reaches the internet through a
gateway peer entirely over 2.4 GHz. This is the Channel T vision working
end to end: consumer-style connectivity on hardware PHY.

## The daemon

`trios_radiod` (trios-mesh/src/bin/trios_radiod.rs) — the mesh core of
trios_meshd (per-hop ChaCha20-Poly1305, HELLO/ETX routing, multi-hop
forwarding, M4 gateway) with the UDP link swapped for a `RadioLink`:

- TX: one persistent `iio_writedev` fed a continuous IQ stream (silence
  between frames + a 2048-sample inter-frame gap so bursts stay separable);
  frames arrive via an mpsc channel from every peer link's `send`.
- RX: one persistent `iio_readdev`, DC/own-LO-leak notch (a node's own
  continuous TX leaks carrier into its RX), O(1)-per-sample envelope burst
  slicer, per-burst peak normalization, `rx_recover`, then peer mapping by
  the PLAINTEXT wire header src `[2..6]`. Self-frames (src == me) dropped —
  radio is a broadcast medium and every node hears its own TX.
- HELLO cadence gets random per-tick jitter (fixed offsets drift into long
  aligned-collision windows on a shared half-duplex air).

## Gate results (2.4 GHz, 4 MSPS, manual 40 dB RX gain, boards cabled to NOTHING but power+console)

1. On-board demod (board 1 TX -> board 3 RX, both demodulating on ARM):
   10/10 frames F01..F10 recovered in order.
2. Reverse + simultaneous bidirectional: board 3 -> board 1 (5/5); both
   TX at once with all three listening — every board heard both streams.
3. Three-node radiod mesh: ETX converged (11<->13 to 1.00), HELLO beacons
   exchanged over the air, node 11 -> node 13 DATA DELIVERED.
4. INTERNET OVER RADIO (M4): node 13, no Ethernet, ran with TRIOS_FETCH=11.
   It sent a FETCH request over the air; gateway node 11 (the only node
   with an uplink) fetched the public IP and sent it back over the air:

```
node 13: FETCH internet via radio mesh -> gateway 11: Forwarded(11)
node 11: gateway fetched "182.232.227.12" -> reply to 13: Forwarded(13)
node 13: INTERNET-VIA-RADIO-MESH: 182.232.227.12
```

"If any one node has internet, everyone has internet" — demonstrated on
hardware over the air.

## Defects found and fixed while bringing radiod up

1. One-shot `iio_writedev` returns before the DMA plays the buffer -> frame
   never radiated. Fix: persistent writer streaming silence between frames.
2. Naive O(n) pre-buffer (`Vec::remove(0)` per sample) stalls the 4 MSPS
   stream on ARM -> most bursts dropped (2/10 delivered). Fix: fixed ring
   buffer, O(1) per sample -> 10/10.
3. AGC amplifies idle noise to its setpoint, blinding an absolute envelope
   detector. Fix: manual RX gain + noise-floor calibration on startup.
4. A node's own continuous TX leaks LO/DC into its RX passband and pins the
   detector. Fix: slowly tracked DC notch, frozen during bursts.
5. Back-to-back frames fuse into one burst (rx_recover is single-burst).
   Fix: inter-frame silence gap in the TX stream.
6. Fixed HELLO jitter still collided on the shared air. Fix: random jitter.

## Wire-free re-test (2026-07-08, boards 2 AND 3 physically off Ethernet)

Repeated with only board 1 wired (gateway); boards 2 and 3 driven purely
over their UART consoles. Board 13 (fully wire-free) fetched its public IP
`182.232.227.12` over the air again — `INTERNET-VIA-RADIO-MESH`. The
11<->13 radio link is solid; internet flows to the wire-free node.

Board 12 did NOT join the mesh (neighbors `{11=inf, 13=inf}`). Directed
diagnostics isolated the cause and cleared its hardware:
- board 12 TX -> board 13 (proven RX): 3/3 frames decoded — TX works.
- board 13 TX -> board 12 (standalone radio_rx): 3/3 decoded — RX works.
- but in `trios_radiod`, board 12 was deaf.

Root cause: board 12 has poorer TX/RX antenna isolation, so its own
continuous TX LO leak inflated the daemon's raw noise-floor calibration
(221 vs ~50 on peers). With threshold = 6x floor, incoming frames never
crossed it. The standalone radio_rx works because it does not transmit
during calibration. Fixed in trios_radiod: calibrate the floor from the
POST-notch signal, median not mean (commit on branch). Deploying the
fixed binary to a wire-free board over the 115200 console proved
unreliable (824 KB; the console session breaks under a multi-minute
stream) — this is the documented ramdisk/off-network deployment gap; a
1-second Ethernet replug or SD bake deploys it cleanly.

## Board 12 brought into the mesh — RX cal fix + TX-gain knob (2026-07-08)

After a brief Ethernet replug deployed the calibration fix to board 12, its
behavior was fully characterized:
- Post-notch median calibration dropped its noise floor 221 -> 124, and it
  now DETECTS and DEMODULATES peer frames (1196 bursts; src=11, src=13, and
  its own src=12 all decoded) — a total-deafness -> hears-everyone jump.
- But neighbor ETX stayed `inf`: the frames modem-decode yet fail the AEAD
  open, because board 12 hears its OWN transmit so loudly (827 self-frames
  decoded) that it collides with/corrupts incoming frames.
- Turning board 12's TX down (`TRIOS_TXGAIN=-12`, new env knob) removed the
  self-interference and it converged to neighbor 13 (ETX 1.0-1.3) and its
  FETCH request reached the gateway (board 11 logged `gateway fetched` once).

Then the hard wall: with all three nodes actively beaconing on a shared
half-duplex channel and NO CSMA, collisions destabilize every link — even
the previously rock-solid 11<->13 dropped to `inf` once board 12 joined
the contention. The link flaps (converges to ~1.3, drops, re-converges).

Net: 2-node radio links are solid and carry internet; a 3rd active node
without medium-access control collapses stability. The RX-cal fix and
TX-gain knob are real and necessary but not sufficient — CSMA
listen-before-talk is the required next milestone, not a tuning knob.

## Honest limits

- Half-duplex, no MAC/CSMA: nodes still occasionally collide; the 11<->12
  direct link flaps (ETX inf) while 11<->13 holds — bench geometry + no
  medium access control. Throughput is one short frame per ~hundreds of ms.
- Digital modem on the host modem code; the AD9361 carries raw IQ. A PL
  BPSK core (spec fpga_bpsk_tx.t27) would offload the CPU and raise rate.
- Gateway needs DNS (`/etc/resolv.conf`) — set at runtime, not persistent.
- 2.4 GHz ISM bench radiation only; a fielded system needs the RF/legal work.

## Next

- CSMA-style listen-before-talk to kill collisions; then stable 3-node
  convergence and M5 self-heal over the air.
- Persist DNS + binaries via SD (binaries already baked to /mnt/boot/bin).
- Move the modem into the FPGA PL for real throughput.
