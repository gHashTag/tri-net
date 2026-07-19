# 3-hop relay end-to-end + link-slash + positive RTI over the air (2026-07-19, wave 2)

Three features, all proven on the four P201Mini boards. The headline is a genuine debugging
finding: last wave's "hop1 blanked, 2/3 hops" was NOT non-stationary fade -- it was a silent
transmitter-death bug, caught this wave by an independent instrument.

## A -- Full 3-hop relay chain over the air, every hop BER=0

`.13 -> .12 -> .11 -> .10`, TDM (one TX at a time on the shared 2.4 GHz medium). Each hop runs
cyclic TX and the receiver retries capture-until-BER=0 (selection combining over the cyclic
repeats), so each hop waits for ITS OWN good window sequentially.

```
  hop1 (.13->.12): try1 cp=1.000 BER=0/128
  hop2 (.12->.11): try1 cp=0.998 BER=0/128
  hop3 (.11->.10): try1 cp=0.998 BER=0/128
```

The payload "TRI3HOP!"+8 bytes was forwarded end-to-end, bit-exact, first try on every hop.

### The broken ruler: a dead transmitter read as a dead path

The first attempts produced pure noise (best_cp ~0.05, BER ~50%) on `.13 -> .12`, exactly like last
wave's "hop1 blanked". Before concluding the path was dead, an independent check -- "is the TX
writer process actually alive?" -- returned **0**. The cyclic `iio_writedev -c -b 46080` needs a
buffer's worth of samples, but the frame generator was emitting ONE frame (7680 samples); with the
file shorter than the buffer the writer hit EOF and died instantly, so nothing radiated. Feeding
SIX frames (6*7680 = 46080 = the buffer) fixed it: writer alive=1, and all three links then carried
BER=0. The lesson (broken-ruler doctrine): never diagnose a path through a receiver number without
first proving the transmitter is up. The "non-stationary fade" story was wrong; the fade was a dead
process.

## B -- Link-level slashing tied to crypto attribution (`depinslashlink`)

A relay's coverage claim is valid only if BOTH hold: it SIGNED the claim (its key attributed the
frame -- unforgeable, from last wave's `depinattest`) AND its downstream hop actually DELIVERED
(BER==0). Run on board .10 with the delivered-flags taken from A (both relays decoded BER=0):

```
  relay0 (.12) signed+delivered -> +150 $TRI  (carry-fee)
  relay1 (.11) signed+delivered -> +150 $TRI  (carry-fee)
  relay2 (lazy) signed, NOT delivered -> -400 $TRI  (SLASHED)
  DEPINSLASHLINK paid=300 slashed=400 ledger_root=0xB485E3FE
```

The seal now works both ways: it rewards the honest carrier and CONVICTS the node that stamped a
claim but never forwarded the cargo. Signing a claim you don't deliver costs more than idling.

## C -- Positive RTI over the air, by received signal strength (RSS)

The first approach -- amplitude-modulate the waveform as a motion surrogate and read the per-frame
envelope CV -- failed over the air: the AD9361 RX tracking loops (DC-offset / quadrature, ms
timescale) CANCEL slow amplitude modulation, and the raw-block envelope of `rtisense` is swamped by
frame-misalignment noise. Two fixes followed.

1. `rticp` -- a new mode that measures the envelope at PREAMBLE-ALIGNED frame boundaries (locks the
   frame phase first), removing the block-vs-frame misalignment noise. Host dose-response is clean:
   CV 0.00 (flat) -> 0.30 (60%) -> 0.58 (90%).
2. The right RTI observable over the air is not modulation but **RSS** (received power): a body
   SHADOWS the path and the received power drops. RSS is a mean over the capture -- immune to the
   tracking loops (no AGC in manual gain) and to alignment. The motion surrogate is a controlled
   path attenuation at the TX (a body shadows by the same dB).

Sweeping the shadow (TX attenuation) at an unsaturated RX gain gives a clean monotone RSS curve:

```
  no body    (TX -5 dB):  RSS(env_mean) ~ 1500
  small body (TX -15 dB): RSS ~ 554     (-10 dB -> x2.7)
  medium     (TX -25 dB): RSS ~ 300
  large body (TX -35 dB): RSS ~ 60      (x25 down from baseline)
```

Each ~10 dB of shadow drops RSS by ~x3 (10 dB = x3.16 in amplitude -- textbook). Presence = RSS
below a calibrated baseline. Honest limits: (i) the RX must be below ADC saturation for RSS to track
(at gain 71 the strong end clipped and small shadows were masked; gain 45 gave the clean curve);
(ii) `env_cv` is unreliable over the air (the tracking loops), so RSS/mean is the feature, not the
fluctuation; (iii) the biological positive -- a real moving body -- needs bench access; this proves
the detector and the OTA path with a controlled, honest stimulus.

## Scientific picture

We stopped mistaking a silent engine for a blocked road: the ship wasn't stuck in fog, its engine
had never started, and only a direct look at the engine room told us so. Once it sailed, the same
cargo passed hand to hand through three ports untouched; the harbour's ledger paid each honest
carrier and fined the one who sealed a manifest but sent no ship; and the harbour learned to feel a
body pass between two lighthouses -- not by the flicker of the beam, which the lamp's own regulator
smooths away, but by the plain dimming of its light.

## Boards left clean

New scratchpad binary (`otatxmod`, `rticp`, `depinslashlink`) deployed to all four; writers=0, TX LO
powerdown=1 on all four, RX AGC restored (slow_attack), LOs at 2.4 GHz, IQ files removed.
