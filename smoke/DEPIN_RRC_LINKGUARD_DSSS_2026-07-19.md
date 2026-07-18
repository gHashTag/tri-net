# RRC pulse shaping + honest link guard + true DSSS processing gain (2026-07-19)

Three upgrades. The **link guard runs on the real boards** and correctly reports the RF link as
degraded (it has not recovered since the previous wave); RRC and DSSS are host-verified DSP with
quantitative numbers. No fabricated OTA figures -- the guard is precisely the tool that makes
faking one impossible.

## 2 -- The honest link guard (`linkq`): correlation, not power

Last wave a stuck-DMA / dead-antenna link read `0/1` and looked like a decode bug; only an
independent instrument (received power) revealed there was no signal. This wave turns that lesson
into a tool the rig runs **before** every decode. `linkq <floor>` locates the best DBPSK-preamble
correlation over the capture and reports the normalized peak `cp` (1.0 = clean lock, ~0 = no
signal), exiting non-zero if `cp < floor` so a script gates on it.

The point is that **rms lies and correlation does not**. On host:

```
  clean signal          cp=1.000  rms=2199    -> LINK OK
  signal buried in noise cp=0.080  rms=25772   -> LINK DEGRADED
```

The noisy case has a HIGHER rms than the clean one (it is full of noise power), yet its correlation
is near zero -- rms would call it "strong", correlation correctly calls it dead.

On the **real 4-board rig** (transmitter up, writers=1, TX at -5 dB), the link that carried the
previous features is still down:

```
  .13 TX -> .10 RX, manual gain 20/40/60:  cp = 0.075 / 0.103 / 0.154  -> LINK DEGRADED (all)
```

So the honest verdict is delivered on the actual hardware: the RF path is degraded (a physical
antenna/thermal/bench issue), and the guard says so instead of emitting a misleading `0/1`. This is
the "auto-detect degradation" half of the option; the "OTA re-run" half waits for the bench.

## 1 -- RRC pulse shaping: room to pack channels

Last wave found the wall on channel density: unshaped (rectangular NRZ) BPSK has a sinc spectrum
whose sidelobes fall as ~1/f, so a neighbour's skirt spills into the wanted channel and caps the
spacing at ~2 MHz. Root-raised-cosine shaping replaces the rectangular symbol with a smooth pulse
whose spectrum is (1+beta)*Rs/2 wide and whose sidelobes fall far faster. Measured
adjacent-channel-leakage ratio (energy in a 400 kHz window at the neighbour vs at the wanted
subcarrier), same random bits, beta=0.25, 8-symbol span:

```
  neighbour offset   rectangular      RRC beta=0.25
     1.0 MHz          -9.2 dB           -11.6 dB
     1.5 MHz         -15.1 dB           -29.9 dB     (~15 dB cleaner)
     2.0 MHz         -18.1 dB           -51.5 dB     (~33 dB cleaner)
```

At 2 MHz the RRC neighbour leaks 51 dB below the wanted signal versus the rectangular's 18 dB --
that 33 dB is exactly the headroom that lets channels move closer (or the same channels tolerate
far more power imbalance). The narrower main lobe and the fast-decaying skirt are the transmit-side
fix the last wave's honest boundary asked for.

## 3 -- True DSSS processing gain (a UNIQUE payload, not repeats)

The previous "processing gain" was coherent averaging of a *repeated* frame -- a preview. This wave
spreads a **unique** payload: every payload bit is multiplied by an N-chip PN code (bit=1 inverts
it), DBPSK'd onto the subcarrier, and the receiver despreads by integrate-and-dump over each chip
(SOFT differential, not the hard +-1 detector, which otherwise saturates each sample to a coin flip
and caps the gain) then correlates the N chips against the code. Spreading buys ~10*log10(N) dB.

Host, 32-bit payload `DEADBEEF` (every bit different), signal amp ~2200:

```
              N=1 (unspread)   N=7          N=31         N=63
  sigma=4000   BER 5/32         BER 0/32     BER 0/32     BER 0/32   (deadbeef)
  sigma=6000   BER 11/32        BER 1/32     BER 0/32     BER 0/32
```

At sigma=4000 the raw link is broken (5 of 32 bits wrong) and a 7-chip spread already delivers the
exact payload; at sigma=6000 it takes N=31. This is the real spread-spectrum gain on non-repeating
data -- the long-range / low-power path for a mesh node -- and it uses the soft differential
detector added this wave. Full DSSS despreading in the PL still needs Vivado + ADI-HDL.

## Scientific picture

The link guard is a stethoscope, not a bathroom scale: a corpse can be heavy (high rms of noise),
but only a heartbeat (preamble correlation) says it is alive. The rig now listens for the heartbeat
before it claims to have heard a word.

Rectangular pulses shout with hard edges, and hard edges splash energy far across the band -- like a
square wave's endless harmonics. RRC rounds the shout into a smooth swell that stays in its own lane;
the neighbour two lanes over barely hears it (-51 dB), so lanes can be painted closer together.

DSSS is telling a secret by spelling it in a long agreed code and repeating each letter's code
thirty-one times: any single click of static flips at most a few chips, and the majority of the code
still spells the letter. The longer the code, the louder the whisper reads through the storm.

## DSSS on a big FPGA: still blocked; OTA re-run: pending a stable bench

Re-scan: only `.1` (router), `.10/.11/.12/.13` (four P201Minis), the host. The RF link is degraded
(guard-confirmed on hardware). All modes cross-compiled and deployed on ARM.

Boards left clean: writers=0, TX LO powerdown=1 on all four, RX AGC restored, LOs at 2.4 GHz, IQ
removed.
