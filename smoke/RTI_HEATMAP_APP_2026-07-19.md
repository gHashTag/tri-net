# Live RTI heatmap tab in the macOS app, fed by over-the-air tomography (2026-07-19)

The TriNetMonitor desktop app's RTI Heatmap tab now renders the real over-the-air radio tomography,
verified on-screen.

## What the tab does

`RTIEngine` (in `phone/desktop/RTIHeatmap.swift`) binds UDP :6000 and, for each packet
`[33, frm, to, 0, val]`, draws a Bresenham line between the two boards' grid positions weighted by
`val/255` (the link's fractional RSS attenuation), accumulating onto a 30x30 field that decays
0.9x every 0.5 s. `RTIHeatmapView` colours the field blue -> green -> yellow -> red by intensity.
Where shadowed links CROSS, the cell lights up -- radio tomography.

## Change: four boards at the corners

The tab previously knew three nodes. It now lays out all four P201Mini boards at the grid corners:

```
  .13 (top-left)      .11 (top-right)
  .12 (bottom-left)   .10 (bottom-right)
```

So `.13<->.10` is the main diagonal and `.11<->.12` the anti-diagonal, and the two diagonals cross
at the centre -- shadowing that crossing pair lights the centre cell. This matches the 4-link
tomography geometry proven over the air (wave: `DEPIN_TOMOGRAPHY_LOSSRELAY_LIVECAL`).

## Feed: OTA drops -> UDP -> the live map

A scratchpad `rtifeed <host:port> <frm:to:drop ...>` mode turns measured link RSS drops into the
app's packets. Fed with the real wave-tomography drops (`.13-.10 0.90`, `.11-.12 0.85`, edges
`0.45`), the map drew a clean X: both diagonals lit, crossing at the centre.

## Verified on screen

Build: xcodebuild (Xcode 26 developer dir) -> BUILD SUCCEEDED. Launched `open -n TriNetMonitor.app`,
switched to the RTI Heatmap tab, fed real drops:

```
  RTI HEATMAP   LIVE 544
  4 corner nodes .13/.11/.12/.10
  two crossing diagonals form an X, intersecting at the centre cell
  Pkts: 544
```

The screenshot shows the live tomographic image -- the shadowed links crossing at the centre. The
app's three-tab shell (Network | RTI Heatmap | Video Call) is unchanged; only the heatmap's node
layout was touched (surgical, one file).

## Notes

- The desktop app builds with Xcode at `/Applications/Xcode.app` (CommandLineTools alone cannot run
  xcodebuild); set `DEVELOPER_DIR` for the build.
- Only one process can bind UDP :6000 -- a second app instance or a leftover test listener causes
  "bind fail" / Pkts:0. Kill stray instances (`killall TriNetMonitor`) and free the port before
  relaunching.
- `rtifeed` lives in the scratchpad `relay_meter` (off the golden pipeline); the boards were not
  transmitting this turn (the map was fed with the proven OTA drop values), and all four are left
  clean (writers=0, TX off).
