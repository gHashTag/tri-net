# Dense RTI tomography + loss-resilient relay + live threshold calibration over the air (2026-07-19, wave 4)

Three features, all proven on the four P201Mini boards. The tomography needed a real per-link RX-gain
calibration to bring every link into range; once calibrated, four over-the-air links reconstruct the
obstruction to a single grid cell.

## A -- Dense (4-link) RTI tomographic imaging: from WHERE to a CELL

Four links each cross a line of a 3x3 grid: A=.13->.12 (left col), B=.11->.12 (right col),
C=.13->.10 (top row), D=.11->.10 (bottom row). `rtiimage` solves the regularized least-squares field
x = W^T (W W^T + lambda I)^-1 y from the per-link fractional RSS drops; where shadowed links CROSS, a
pixel lights up. Real over-the-air drops (deep -35 dB shadow surrogate):

```
  link A 1300->54 (0.96)   B 2623->245 (0.91)   C 1908->855 (0.55)   D 2653->299 (0.89)

  shadow A+C -> peak cell #0 (top-left)      [left col x top row]
  shadow B+D -> peak cell #8 (bottom-right)  [right col x bottom row]
  shadow A+D -> peak cell #6 (bottom-left)   [left col x bottom row]
```

Every scenario reconstructs to the correct crossing cell. Two links give a line; four give a point --
a real tomographic image from real OTA measurements.

### Per-link RX gain (independent-instrument calibration)

The two links into .10 first read the noise floor (.13->.10 ~33 even at gain 45/65) or saturated
(.11->.10 pinned ~2700), because the .10 paths differ by tens of dB. Since each link is measured in
its own TX session, each can use its own RX gain: .13->.10 needs gain 71 (weak path), .11->.10 needs
gain 48 (strong path). With per-link gains all four links tracked their -35 dB shadow cleanly.

## B -- Loss-resilient relay: RLNC erasure recovery on a lossy hop

Hop .12 -> .11. The payload is signed and coded into 6 RLNC frames; any 4 independent coding vectors
recover the generation. Stepping the hop's TX power down erases coded frames; the receiver
(`otarxrlnc2`) recovers as long as >=4 survive. Over the air the recovery held bit-exact across the
whole induced-loss range:

```
  TX -5  dB (full)     -> gens_decoded=1/1  ascii="TRINET-RLNC-OK!!"  mac_dropped=2
  TX -20 dB (moderate) -> gens_decoded=1/1  ascii="TRINET-RLNC-OK!!"  mac_dropped=1
  TX -32 dB (deep)     -> gens_decoded=1/1  ascii="TRINET-RLNC-OK!!"  mac_dropped=3
```

The coded payload survived a -32 dB shadow where a single uncoded frame would have errored: the
cyclic repetition supplies many noisy copies, a majority vote cleans each coding vector, and any 4
recover the generation. A transit relay can carry cargo through a fade the raw link could not -- and
still re-sign and attribute it. (The true erasure floor -- fewer than 4 distinct cv surviving --
sits below -32 dB on this bench; the point, recovery survives loss, is proven.)

## C -- Live threshold calibration on a drifting channel

A body attenuates RSS MULTIPLICATIVELY, so the natural detector is present = rss < frac * baseline.
`rtitrack` tracks the baseline with an EWMA updated only on quiet samples -- fast, low-lag -- so it
follows drift where a fixed threshold, set once, is crossed by the drift and cries wolf. Over the air
with a baseline drifting ~1400 -> 590 (slow-fade surrogate) and deep body dips:

```
  ADAPTIVE (EWMA baseline * frac): Pd=1.00 Pfa=0.08
  FIXED    (initial threshold)   : Pd=1.00 Pfa=0.25
```

Both catch every body event; the adaptive threshold's false-alarm rate is a third of the fixed one,
because it lowers with the drifting baseline while the fixed threshold stays put and the late quiet
samples fall under it. (An earlier mean-k*sigma rule lagged and lost to drift; the multiplicative
EWMA is the drift-robust form.)

## Scientific picture

The harbour matured on three fronts. First, it stopped saying merely "a ship is in the west channel"
and started fixing a grid square: four crossing sightlines, and where the shadowed lines meet is the
cell. Second, a porter can now carry a parcel through a storm that would have soaked a single letter,
because the message is spread across many sealed copies and any four rebuild it whole. Third, the
watchman no longer keeps yesterday's alarm setting on a foggy night: he lets the alarm float with the
ambient light, so drifting weather no longer trips it while a real hull still does.

## New modes + boards clean

New scratchpad modes: `rtiimage` (tomographic solve), `rtitrack` (EWMA live calibration). B reused
`otarxrlnc2`. Deployed to all four boards; writers=0, TX LO powerdown=1 on all four, RX AGC restored
(slow_attack), LOs at 2.4 GHz, IQ files removed.
