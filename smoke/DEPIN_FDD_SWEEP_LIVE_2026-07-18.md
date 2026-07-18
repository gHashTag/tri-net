# FDD channel-spacing sweep + live changing source (2026-07-18) -- "все три"

Two more radio results on the 4 P201Minis; the third (DSSS on a big FPGA) stays blocked.

## 1 -- Minimum frequency separation for concurrent FDD (self-desense)

.13 transmits msgA @ 2.40 GHz. .12 receives @ 2.40 while transmitting a DIFFERENT interferer
message @ (2.40 + delta), and we ask: does .12 still recover .13's msgA (seal 0xE0AA4F5D) as
delta shrinks? RX rf_bandwidth = 18 MHz.

| delta   | .13 msgA recovered | verdict         |
|---------|--------------------|-----------------|
| 50 MHz  | 5/5  seal match    | **heard .13**   |
| 20 MHz  | 5/5  seal match    | **heard .13**   |
| 15 MHz  | 4/5  wrong seal    | desensed        |
| 13 MHz  | 4/5  wrong seal    | desensed        |
| 10 MHz  | 4/5  wrong seal    | desensed        |
| 5 MHz   | 4/5  recovers the INTERFERER | fully captured by own TX |

**Minimum clean separation ~20 MHz on one chip** (threshold between 15 and 20 MHz), consistent
with the 18 MHz RX passband (half = 9 MHz) plus the filter roll-off and the TX signal's own
width.

**The limit is ANALOG, not digital.** Narrowing the RX digital filter to 4 MHz did NOT help at
delta = 5 MHz -- .12 still decoded its OWN interferer (msg_hex started "INTERFERER..."). The
board's own TX saturates the shared RX front-end before the digital filter can act, so tighter
channel packing needs external RF isolation (a duplexer or separate antennas), not a narrower
digital filter. Honest, useful ceiling for mesh channel planning.

## 2 -- Live changing source through the FDD relay

The source is no longer a fixed string: .13 cycled an incrementing counter, each tick relayed
concurrently .13 -> (2.40) -> .12 -> (2.45) -> .10.

```
.13 "TRINET-LIVE-STREAM-T=01!"  ->  .10 "TRINET-LIVE-STREAM-T=01!"
.13 "TRINET-LIVE-STREAM-T=02!"  ->  .10 "TRINET-LIVE-STREAM-T=02!"
.13 "TRINET-LIVE-STREAM-T=03!"  ->  .10 "TRINET-LIVE-STREAM-T=03!"
```

Every changing message arrived intact at the far node through both concurrent radio hops -- the
network carries LIVE, changing content (telemetry / a counter / user input), not a static test
pattern. This is the "live source over the mesh" capability on real radio.

## 3 -- DSSS on a big FPGA: still blocked

Re-scanned network and USB: only .1 (router), .10/.11/.12/.13 (four P201Minis), the host -- no
big FPGA reachable, none on USB/JTAG. A radio-preserving DSSS bitstream needs Vivado + the ADI
HDL AD9361 datapath (the open toolchain here cannot consume the AD9361 IP), or a bigger FPGA
board that is not on the network. Unchanged from last wave: gate satisfied, artifact/tooling
absent.

## Honest boundary

- Channel-spacing threshold bracketed to 15-20 MHz (not swept to the exact MHz); dominated by
  analog TX->RX isolation on the shared chip.
- Live source = discrete ticks (restart TX per message), not a continuously-fed streaming buffer.
- DSP mod/demod is scratchpad Rust in relay_meter; the receipt it seals IS t27 (tri_depin).

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, LOs restored to 2.4 GHz, RX
bandwidth restored to 18 MHz, IQ removed.
