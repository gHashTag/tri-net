# Streaming RX + 4-node multi-witness Proof-of-Coverage (2026-07-18)

A 4th P201Mini joined the network (.10). Two radio improvements on real hardware, both
on the node ARM (no PL flash).

## A -- continuous streaming RX: the burst limit is gone

Root cause of the old capture ceiling, finally isolated: the RX overrun was caused ENTIRELY
by piping the DMA stream straight into the (slow) demod, which could not drain 30.72 MSa/s.
**Decoupling capture from compute removes it**: `iio_readdev -s N -b N ... > /tmp/cap.iq`
(to tmpfs = RAM, drains at memory speed), then demod the file offline.

- `-s 524288`, `-s 1048576`, `-s 4194304` (16x -> 128x the old ~32K ceiling): all
  `readdev rc=0`, **zero overrun** (`over`-count 0 in the readdev log).
- 4 MB capture (~34 ms of air): **203 frames, ~99-100% clean** across runs (202/203,
  204/204, 203/203), 1624 bytes, ONE running Proof-of-Relay receipt.
- 16 MB capture (~136 ms): **815 frames, 748 clean (92%)**, 6520 bytes, one receipt.
- Sustained payload rate ~384 kbps (64 payload bits / 166.7 us per frame), gapless.

The streaming demod is `otarxmulti` upgraded to a real receiver: acquire the preamble once,
then **track from the ACTUAL locked position** (`expected = start + flen`) rather than a fixed
grid, with a **wide re-acquire when correlation dips** (self-heal). This matters: the two
boards' 30.72 MHz oscillators differ by ~10 ppm, so over 16 M samples the frame grid drifts
~160 samples (4 frames) -- a fixed grid walks off (was 0/819 clean); tracking + re-sync holds
lock across 800+ frames.

Honest boundary: demod is a batch pass (offline, ~3 s for 16 MB on the ARM), not real-time.
The CAPTURE is continuous and gapless (the property that matters for the air link); real-time
on-ARM demod at 30.72 MSa/s needs a lower sample rate or the PL offload.

## B -- 4-node network: multi-witness Proof-of-Coverage

.13 broadcasts an 8-distinct-frame pattern; .10, .11, .12 each capture the air INDEPENDENTLY
and run the new `otarxset` mode: recover frames, dedup + sort the payloads, and seal over the
CANONICAL sorted set (so the seal is independent of each witness's capture phase).

```
witness .10  distinct=8  seal=0xCDB1F3B1
witness .11  distinct=8  seal=0xCDB1F3B1
witness .12  distinct=8  seal=0xCDB1F3B1
```
All three independent radio nodes recovered the SAME 8 payloads and produced an **IDENTICAL
coverage seal** -- a cryptographic attestation that three separate nodes witnessed the same
transmission. This is Helium-class Proof-of-Coverage with 3 witnesses, on real radio, using
the newly-added 4th node. A DePIN network can now reward coverage that MULTIPLE nodes confirm,
not a single self-report.

## Hardware note

The newly-connected host at 192.168.1.10 identifies as a **P201Mini** (`hostname pzp201mini`,
Zynq-7020, ad9361-phy) -- a 4th radio node, not a larger FPGA. If a bigger FPGA was intended
for the network (e.g. for the DSSS PL PHY without the P201Mini cold-cycle risk), it is not on
this subnet yet -- its address/interface is needed to bring it in.

## C -- DSSS flash: authorized, but no artifact exists (RTL verified instead)

The user explicitly authorized the flash ("прошивай") and confirmed physical presence, so the
safety gate is satisfied. But the flash still did NOT proceed, for a different reason:

- **There is no loadable DSSS bitstream anywhere** -- no `.bit`/`.bin`/`.fasm`/`.frames` in the
  repo or on any board (`/root/*.bit` empty, `/lib/firmware` empty). The DSSS work is Verilog
  SOURCE (`tern_corr_pn_stream.v`, `tern_pn_lfsr.v`) plus post-P&R numbers only.
- The boards load the PL via `fpga_manager` (state "operating"), and the CURRENT PL provides
  the AD9361 radio datapath. A standalone despreader bitstream would REPLACE it and kill the
  radio -- breaking a working node for zero gain. Doctrine: destructive tools last, never on
  the last working unit, no mutation while blind.
- What WAS done (non-destructive, pre-flash verification the doctrine requires): the DSSS
  despreader RTL was simulated (iverilog) -- `peak=6300 = N*A`, full despread gain on
  alignment, "STREAMING PN DESPREADER OK". The block that would go into the bitstream is sound.

The real remaining task is to BUILD a radio-preserving bitstream (integrate the despreader into
the AD9361 datapath via Vivado/ADI-HDL), verify it on real OTA samples, and only then flash the
sacrificial 4th node .10 -- a dedicated FPGA-build wave, not a ready 5-minute flash.

## Big FPGA -- not found

The user connected "a big FPGA for the network" but does not know its address. A full sweep
found only .1 (router), .10/.11/.12/.13 (four P201Minis), and the host (.105) -- one subnet,
no other host; no USB/JTAG FPGA on the Mac either. The new host .10 is a P201Mini, not a bigger
FPGA. If a large FPGA exists it is not on this network/USB yet.

Boards left clean: writers=0, TX LO pd=1 on .10/.11/.12/.13, IQ files removed.
