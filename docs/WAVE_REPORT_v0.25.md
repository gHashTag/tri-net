# Wave v0.25 — the radio carried a signal; a relay carried a chain; the app caught up

## THE RADIO (the headline)

Three facts changed today, each measured:

**1. `.11` is a full radio node — first in the project's history.** A warm
`reboot` (the "state flips between power events" memory, tested at last) brought
up the ENTIRE chain:

```
ad9361-phy:             AD936x Rev 0 successfully initialized
cf-ad9361-dds-core-lpc: probed DDS   (TX)
cf-ad9361-lpc:          probed ADC as MASTER   (RX -- a device .12 never had)
```

**2. The radio silicon carried a signal, end to end.** Two experiments on `.11`,
both non-emitting and legal:

- RX path alive: raw capture with no stimulus shows live noise
  (`00eb ffa9 005c ...`).
- A DDS tone on TX, looped INSIDE the AD9361 (debugfs `loopback=1`), captured on
  RX: `03fe 03ff 03fe 03fd 03fc 03fa 03f8 03f5 03f2 ...` — a clean sine crest,
  Q channel zeroed. **The transmit path fed the receive path through the radio
  core.** First data through the radio in the project's history. The board was
  left clean (loopback off, tone muted).

**3. `.12`'s radio failure is DIAGNOSED, not mysterious.** Its RX core was in
the device tree all along and failed at `ad9361_dig_tune_delay: Tuning RX
FAILED!` — a digital-interface timing calibration, not absent hardware. So even
the "good radio" board never had a receive path; the phy alone was up. A driver
rebind hit `Failed to get converter device: -19` (the phy must re-probe first),
and the full soft re-probe cycle **hung the board** — the phy unbind deadlocked
in the kernel with the DDS holding its clocks. Nothing was written to flash.

**`.12` needs a power cycle** — and that is now an *opportunity*, not a chore:
a mere warm reboot resurrected `.11`'s entire radio, and a cold cycle re-runs
`.12`'s RX tune from scratch. If it comes up, the project has TWO full radios
and the cabled SMA + attenuator link is the only remaining step.

Operational fact learned: `/root` is tmpfs — every reboot erases deployed
daemons. Re-upload after any power event.

## Multi-hop: chain backpressure works

A node started with `NEXT_HOP=<ip>` is a RELAY: no device, every mesh fragment
forwarded untouched (cut-through, no reassembly), and its upstream rx-report
carries `fb_chain_report = min(what reached me, what my downstream reported)`.
The bottleneck propagates to the origin hop by hop; no hop knows the chain's
length.

Verified on hardware (Mac-origin -> `.11` relay -> Mac-tail):

```
1575 payloads reassembled byte-identical at the tail
relay's upstream report: honest 350/s -> tail lies "200" -> 200 -> honest -> 350
VERDICT: CHAIN BACKPRESSURE WORKS
```

Cut-through is unpaced today (Ethernet next hop); a radio next hop needs a pacer
at the forward point — marked in the code.

## App: the last pre-feedback relic retired

- **Mesh mode no longer caps bitrate.** The 150 kbps constant was a guess made
  before the node could speak; watched live, it and the node's advice pulled the
  encoder in opposite directions. The node steers now. Mesh mode keeps only the
  per-NAL ceiling (17850B) — wire format, not policy.
- **Node telemetry in both HUDs**: `node 87% · loss 0% · 600/s · hold` beside
  the call stats. It was always arriving; only the log could see it.

Both apps built and installed; 17/17 wire tests. Commit `0e76af4`.

## State of the boards

| board | state |
|---|---|
| .11 | UP, **full radio**, bridge restored (peer .12, device Mac) |
| .12 | **HUNG by my re-probe** — needs a power cycle; flash untouched |
| .13 | DOWN since before this wave |

## Honest status

The radio has now carried a *signal* (a tone through the silicon's own loop).
It has not yet carried a *byte of payload* — that needs a modem on top of the
IIO datapath, and a link needs either `.12`'s RX to survive its cold cycle or
`.13`'s return. The mesh software above the radio is finished to a depth the
radio has yet to deserve: loss-shaped FEC, class separation, adaptive AIMD with
chain-min propagation across relays.

## Three options for the next wave

### 1. Power-cycle .12 (you, one plug)
Cold, on dedicated power if possible. When it returns I re-upload the daemon
(tmpfs) and re-check its RX tune. Two full radios = a cabled link is next.

### 2. BPSK modem over the IIO datapath (software, unblocked NOW)
`.11` alone can run it: modulate real bytes into I/Q samples, push through the
TX DMA, internal loopback, demodulate from RX capture. Bytes-through-radio on
one board, no emission, no cable. The t27 BPSK core exists for the FPGA; a
software modem over libiio proves the datapath while the FPGA route matures.

### 3. Wire the video bridge over the radio path
Once 2 exists: `trios_meshd_video`'s mesh port speaks UDP; a thin shim that
carries mesh fragments over the modem instead of Ethernet turns the proven call
stack into a radio call stack. This is the "интернет из воздуха" step.

**Recommendation: 1 tonight (it is one plug), then 2.** Option 2 needs no
hands at all and turns today's tone into tomorrow's bytes.
