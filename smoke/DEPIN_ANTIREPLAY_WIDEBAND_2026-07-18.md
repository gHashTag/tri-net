# Anti-replay freshness window + wide-band single-radio dual-source capture (2026-07-18)

Two upgrades on the 4 P201Minis, both proven over the air. (1) An **epoch under the MAC** so a
node cannot re-play a captured-but-authentic frame; the receiver enforces a freshness window. (2)
**One wide RX capture split digitally into two FDD bands**, so a single radio harvests two senders
that transmit at the same time on different frequencies. DSSS on a big FPGA stays blocked.

## 1 -- Anti-replay: an epoch under the keyed MAC

Last wave's keyed MAC proved *authenticity* but not *freshness*: a captured valid frame could be
re-sent and would still verify. This wave puts a 16-bit **epoch** counter inside the MAC. The coded
frame grows to 16 bytes: `g:u16 | cv[4] | value:u32 | epoch:u16 | mac32:u32`, and mac32 =
first word of SHA-256(key || the first 12 bytes) via the t27 `tri_sha256` -- so the epoch is
authenticated, an attacker cannot edit it. The receiver drops any frame whose `epoch < min_epoch`
(its freshness window).

The over-the-air proof is deliberately un-foolable. A single epoch=5 transmission from .13 is
captured **once**, then the one capture is decoded two ways:

```
                                      .13 signs epoch=5, captured ONCE @ 2.400 GHz
  decode min_epoch=0   (accept-all)   -> 1/1   mac_dropped=0                "TRINET-REPLAY!!!"
  decode min_epoch=10  (fresh only)   -> 0/1   replay_dropped=24            rejected as stale
```

Because both decodes run on the **same bytes**, the `min_epoch=0` pass proves the frames were
received and are authentic (valid MAC), and the `min_epoch=10` pass proves the rejection is the
*freshness window* doing its job -- not a lock failure. The fresh case (epoch=10, min_epoch=10)
decodes 1/1 with `replay_dropped=0`. A replayed old frame is authentic yet stale, and is binned.

## 2 -- Wide-band: one radio, two simultaneous senders

Last wave's two FDD sources were captured one band at a time. This wave captures **both at once**.
`.13 @ 2.400 GHz` (band A) and `.11 @ 2.404 GHz` (band B) transmit **simultaneously**, each sending
only 2 coded frames of one K=4 generation. The destination `.10` makes ONE wide capture centered at
`2.402 GHz`, then a digital channelizer -- multiply by e^{-j2 pi (f/fs) n} to slew each band to
baseband, followed by a length-16 boxcar low-pass that nulls the adjacent band at +/-3.84 MHz --
extracts each band in turn (mix1 = -2 MHz, mix2 = +2 MHz) and merges the frame lists.

```
  ONE capture @ 2.402 GHz, both senders on air together
  decode BOTH bands (mix1=-2MHz, mix2=+2MHz)  -> 1/1   "TRINET-WIDEBAND!"
  decode band A ONLY (mix2=0)                 -> 0/1   (2 of 4 coded frames -> unsolvable)
```

Each sender alone contributes 2 of the 4 coded frames a K=4 generation needs, so band-A-only fails
by construction; only harvesting both from the single capture reaches rank 4 and decodes. One
antenna, one ADC, two concurrent transmitters recovered.

## The debugging that made the numbers real (broken-ruler)

The first attempts read 0/1 and looked like a demod bug. The independent instrument said otherwise:

- **`pkill` does not exist on this busybox** (returns 127, swallowed by `2>/dev/null`). Every
  "stop the transmitter" was a silent no-op, so stuck `iio_writedev` orphans piled up, each holding
  the DDS/DMA. After the very first (clean-DMA) run, **no board actually radiated** -- yet the
  decoder honestly reported "no signal" as 0/1. Fix: `killall`, and verify writers=0 by reading
  `/proc/*/comm` directly.
- **The AGC confounds the RF power probe.** With `slow_attack` the received RMS *fell* when a
  strong transmitter came on (the AGC cut gain), so IQ-power could not tell "signal present" from
  "noise". Switching RX to **manual gain** made power a truthful instrument and the demod
  deterministic (locks at 40-60 dB).
- **A `nohup`-detached writer streams unreliably** across ssh return. Running the writer in a
  **live foreground ssh** backgrounded from the host guarantees it keeps pushing samples during the
  capture.

The lesson is the project's own doctrine: never diagnose through a signal that lives inside the
failure domain. The decoder's 0/1 was the broken ruler; a stuck writer poisoning the shared DMA was
the fault; and the correct fix had been testing as a failure the whole time.

## Scientific picture

The keyed MAC was a signet ring -- only the key-holder can stamp a valid seal. But a sealed letter
can be photographed and posted again tomorrow; the seal is still genuine. The epoch is a **date
written inside the sealed envelope**: the forger cannot change it without breaking the seal, and the
reader refuses any letter dated before today. Same ring, but now yesterday's orders cannot be
re-issued.

Wide-band is one listener at a crossroads where two heralds shout at once from different hills. A
narrow ear would hear a jumble. Instead the listener **turns toward each hill in turn** (the digital
mix) and **cups a hand to silence the other** (the channel-select filter), writing down each
message cleanly; because the messages are coded, their halves reassemble into the one order. One
ear, two speakers, no collision.

## Honest boundary

- The MAC is still 32-bit truncated SHA-256 (~1/2^32 blind forgery). The epoch defeats *replay of a
  captured frame*, not a same-epoch re-order within the window; a production link pairs the epoch
  with a per-sender monotone sequence and a sliding-window bitmap (as in IPsec/DTLS). `min_epoch`
  here is set by the operator; a real deployment advances it from the highest epoch seen.
- Wide-band uses a length-16 boxcar as the channel filter -- cheap, ~2.4 dB of passband droop, and
  it only *nulls* the adjacent band near +/-3.84 MHz rather than deeply rejecting a whole block. Two
  bands at +/-2 MHz inside the 18 MHz RX passband is the proven geometry; more/closer bands want a
  designed FIR and decimation.
- Frame overhead is +2 B for the epoch (16 vs 14 B). Coding stays MDS-Vandermonde over GF(256); the
  MAC uses the t27 `tri_sha256`.

## DSSS on a big FPGA: still blocked

Re-scan: only `.1` (router), `.10/.11/.12/.13` (four P201Minis), the host. A loadable despreader
bitstream that preserves the radio needs Vivado + ADI-HDL, absent here.

Boards left clean: writers=0, TX LO powerdown=1 on .10/.11/.12/.13, RX AGC restored to slow_attack,
LOs back to 2.4 GHz, IQ files removed.
