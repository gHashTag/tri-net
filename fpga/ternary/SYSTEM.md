# TRI-NET at system scale: the "internet from the air" mesh

Each node = one Zynq-7020 with an AD9361 radio AND a 91M ternary AI, both on the
same chip (ternary frees the DSP column). This is how single nodes become the
field mesh.

## Per-link data rate = chip rate / spreading factor (AD9361 @ 30.72 MSPS)

| SF  | rate/link  | proc. gain | use                                   |
|-----|------------|------------|---------------------------------------|
| 63  | 0.49 Mb/s  | 18 dB      | max robustness / range / jam-resist   |
| 16  | 1.92 Mb/s  | 12 dB      | balanced                              |
| 8   | 3.84 Mb/s  | 9 dB       | **video-capable**                     |
| 4   | 7.68 Mb/s  | 6 dB       | short-range high-rate                 |

## Multiple access (CDMA) + range (multi-hop)

- Nodes share 2.4 GHz, separated by **PN code phase** (m-sequence PN-63 -> up to
  ~63 phases). Honest cap: our measured fine code-phase separation is soft
  (needs chip-sync RX), so ~a few nodes/family in practice; frequency reuse and
  multiple PN families scale N further.
- **Multi-hop relay is already built** (`src/bin/trios_meshd_video.rs`,
  cut-through, proven device->node->node->device). A k-hop chain covers ~k x the
  single-link range -- range without towers or satellites.

## On-node AI (0 DSP, runs beside the radio -- all proven this session)

- **RF classification** (tone / spread / noise, 12/12 on live captures) ->
  spectrum awareness, jammer detection.
- **Routing / link-quality** decisions from a tiny ternary net (~us latency).
- **Local inference** -- the 91M coding/RF model at ~50-130 tok/s (real DDR-bound
  on a 32-bit DDR3-1066 Zynq-7020), on DSPs the radio also never needs.

## vs alternatives

| system     | band        | rate            | note                                        |
|------------|-------------|-----------------|---------------------------------------------|
| Starlink   | satellite   | high            | needs infrastructure + subscription         |
| LoRa-mesh  | sub-GHz     | 0.3-50 kb/s     | very low rate (IoT telemetry)               |
| WiFi-mesh  | 2.4/5 GHz   | high            | short range, no spread / jam-resistance     |
| **TRI-NET**| 2.4 GHz SDR | 0.5-8 Mb/s/link | **spread-spectrum + on-node AI + open + autonomous** |

**"Internet from the air":** autonomous nodes, no satellites or towers,
spread-spectrum links (robust, low-probability-of-intercept), on-node AI for
spectrum and routing, video-capable at SF<=8. A field mesh that talks and thinks
on one cheap open chip. phi^2 + 1/phi^2 = 3.
