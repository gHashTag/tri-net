# Wave v0.26 — two full radios at once, and the power lottery decoded

## The headline: TWO complete radio chains, simultaneously

For the first time in the project's history, two boards hold the full
`phy + DDS TX + RX capture` chain at the same moment:

```
.12: ad9361-phy  cf-ad9361-dds-core-lpc  cf-ad9361-lpc   (RX dig-tune PASSED)
.13: ad9361-phy  cf-ad9361-dds-core-lpc  cf-ad9361-lpc   (RX dig-tune PASSED)
```

The precondition for a radio LINK ("two are needed") is met. What remains
physical is one SMA cable + 30-40 dB attenuator (OTA stays illegal per project
law) — and power for `.11`, which is currently dark.

## The power lottery, decoded

The session finally produced the diagnostic signature of the "wandering radio":

- COLD power-on: the AD9361 frequently does not answer SPI — `Unrecognized
  CHIP_ID 0x0` (chip unpowered/in reset) or garbled `0xF8` (marginal rail).
  Cold boots are a dice roll per board.
- WARM `reboot`: power stays applied, the chip is already alive, and the probe
  succeeds — this resurrected `.11`'s full chain in the morning and `.12`/`.13`'s
  tonight. **The radio lottery is a power-integrity problem, not silicon death.**
- `ensm_mode` can boot as `sleep` (RX DMA times out); on `.12` tonight the
  driver refused to leave sleep via any of wait/alert/fdd. A board that boots
  into `fdd` (`.13`) captures immediately.
- `/root` is tmpfs: every reboot erases deployed daemons.

## Signal through the silicon: now on TWO boards

The DDS-tone-through-internal-loopback experiment (first done on `.11`) was
reproduced on `.13`: clean sine in the RX capture, no emission. The radio
DATAPATH works on both current boards.

## Bytes through the silicon: blocked at the TX DMA, with a named suspect

The BPSK harness (bytes -> I/Q -> TX DMA -> loopback -> RX -> bytes; payload a
real VSTREAM mesh fragment) is written, committed under `tools/radio-bringup/`,
and runs — but the capture shows zeros whenever the data source is the DMA
rather than the DDS generator, with 2-channel and 4-channel layouts alike.
The device tree carries `mwipcore@43c00000`: this is a MathWorks reference
design, and its fabric most likely feeds TX from the MathWorks IP core, not the
DDS DMA mux. Levers, in order: drive the mwipcore datapath; or load the trios
BPSK FPGA core (`specs/fpga/bpsk.t27`, merged in t27 for exactly this), which
owns the datapath explicitly.

## Also this wave (earlier)

- **Relay mode + chain-min backpressure proven on hardware**: 1575 payloads
  byte-identical through `.11` as a cut-through relay; the relay's upstream
  report tracked its downstream's claimed delivery exactly (350 -> 200 -> 350).
- **Mesh bitrate cap retired; node telemetry in both HUDs** — installed.
- **`.12` kernel-hang postmortem**: the phy unbind deadlock is why soft
  re-probes are now off the menu; warm reboot is the sanctioned retry.

## Board state at close

| board | state |
|---|---|
| .11 | dark (did not return from its last warm reboot) — needs a power poke |
| .12 | UP, **full radio** (ENSM asleep), mesh node for the iPhone |
| .13 | UP, **full radio**, ENSM fdd, loopback-verified, mesh node for the Mac |

The mesh now runs `.13 <-> .12`. The Mac should Start to **192.168.1.13**; the
iPhone stays on `192.168.1.12`.

## Three options for the next wave

### 1. Power-poke `.11`, keep everything warm (you)
And after ANY cold boot, expect the radio dead until a warm `reboot` retries it.
Dedicated supplies remain the real fix.

### 2. Bytes over the mwipcore or the t27 BPSK core (software)
The harness is ready and the target is named. When TX DMA data reaches the
loopback, the same run turns tonight's sine into a mesh fragment through the
radio — and the shim (mesh fragments over the modem instead of Ethernet) becomes
mechanical.

### 3. The cabled link (one SMA cable + attenuator, when in hand)
Two full radios are waiting for it. TX of `.13` into RX of `.12` is a real
radio hop the moment the cable exists — the first "интернет из воздуха" link,
legally, on the bench.
