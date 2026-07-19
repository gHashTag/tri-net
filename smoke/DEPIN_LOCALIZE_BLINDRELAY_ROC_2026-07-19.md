# Two-link RTI localization + blind-relay per-hop attribution + RTI ROC over the air (2026-07-19, wave 3)

Three features, all proven on the four P201Mini boards. The RTI work again surfaced a real hardware
gotcha (a TX-gain that silently never takes effect) caught by an independent read-back.

## A -- Two-link RTI localization: not just WHO is there, but WHERE

Two anchors, one tag: link A = TX .13 -> RX .12, link B = TX .11 -> RX .12 (shared receiver, so the
two RSS values are directly comparable). A shadow near one anchor drops THAT link's RSS but not the
other; the drop pattern localizes the obstruction to a region -- the first step of radio tomography.

Real over-the-air RSS (deep -35 dB shadow surrogate), median of 3 captures per point:

```
  link A (.13->.12):  full 1460  ->  shadow 52   (x28 drop)
  link B (.11->.12):  full 2610  ->  shadow 209  (x12 drop)

  no shadow    -> A clear,  B clear  -> NONE
  shadow A     -> A SHADOW, B clear  -> region A only (near anchor .13)
  shadow B     -> A clear,  B SHADOW -> region B only (near anchor .11)
  shadow both  -> A SHADOW, B SHADOW -> BOTH regions (or the shared crossing)
```

`rtilocalize` classifies each RSS pattern to a region. One link says "someone is present"; two links
say where.

### The gain that never took effect (independent-instrument catch)

The first attempts inverted: a "shadowed" link read HIGHER RSS than its baseline. The AD9361 TX
hardwaregain, set BEFORE the sleep->fdd transition, is RESET by the transition -- the attenuation
never applied, so every measurement ran at full power and only channel non-stationarity showed. A
read-back (`echo -35 > hardwaregain; cat hardwaregain` -> `-35.000000`) on a LIVE persistent TX
confirmed the gain sticks only when set AFTER launch. Fixed: measure each link with one persistent TX
and step the gain on the live DDS. RSS then dropped monotonically (single-TX sweep: -5:1453 -15:502
-25:449 -35:38). The two-link script's kill-and-restart-per-measurement was the culprit.

## B -- Blind-relay: per-hop crypto attribution over 3 hops

.13 -> .12 -> .11 -> .10, each sender signing with its OWN key; each receiver runs `depinattest` and
attributes WHO sent to it. Collecting the three attributions reconstructs the full path -- every hop
cryptographically proven, not assumed.

```
  hop1: .13 signs A0A03333 -> .12 attests tally=[30,0,0]  -> node #0
  hop2: .12 signs C0C02222 -> .11 attests tally=[0,29,0]  -> node #1
  hop3: .11 signs B0B01111 -> .10 attests tally=[0,0,23]  -> node #2
  depinpath: origin =OK=> node#0 =OK=> node#1 =OK=> node#2
             full_path_proven=true  paid=300  ledger_root=0xD3D8EAA6
```

A package with three seals: the destination reads the whole chain of hands, each proven by signature,
and pays every honest carrier. This is the composition of the last two waves' attribution + 3-hop
relay into one over-the-air sense -> attribute-per-hop -> pay chain.

## C -- RTI threshold calibration + ROC over the air

`rtiroc` takes quiet-link RSS (no body) and body-present RSS, sweeps the detection threshold, and
reports the ROC. Auto-calibration sets the threshold at mean - 3*sigma of the quiet baseline.

```
  baseline (no body): mean=1298 sigma=288 (n=8)
  body (shadow):      354,330,366,159,341,158,188,763 (n=8)
  AUC=0.984   Youden-opt thr=399 -> Pd=0.88 Pfa=0.00
              auto(mean-3sigma)=435 -> Pd=0.88 Pfa=0.00
```

Presence sensing gets a number: AUC 0.984 over the air, the auto-calibrated threshold detecting 7 of
8 body-present captures with ZERO false alarms (the one miss was a weak-shadow moment under channel
non-stationarity). The sensor now knows where "empty" ends and "someone" begins, and states the cost
of sensitivity.

## Scientific picture

The lighthouse keeper learned three things. First, two lamps beat one: when a hull dims one beam but
not the other, he knows not just that a ship is out there but which channel it sits in. Second, a
package that changes hands three times can still name every carrier, because each porter presses his
own seal and the harbourmaster reads the whole chain. Third, he stopped guessing where "clear water"
ends: he watched the light on many empty nights, learned its natural flicker, and set his alarm just
past it -- so it cries "ship!" almost every time one passes and almost never at a wave.

## New modes + boards clean

New scratchpad modes: `rtilocalize`, `depinpath`, `rtiroc`. Deployed to all four boards; writers=0,
TX LO powerdown=1 on all four, RX AGC restored (slow_attack), LOs at 2.4 GHz, IQ files removed.
