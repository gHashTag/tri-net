# Radio bring-up probes (NOT critical path)

Hardware bring-up utilities per CLAUDE.md's tools/ exemption. They test the
AD9361 datapath through the chip's INTERNAL digital loopback -- no emission,
legal without a cable.

- `bpsk_gen.py`  : bytes -> BPSK I/Q S16LE for the TX DMA. Payload is a real
  VSTREAM mesh fragment. Digital loopback is sample-synchronous, so no carrier
  or timing recovery is needed: Barker-13 locates the frame, sign slices bits.
- `bpsk_demod.py`: RX capture -> bytes, byte-compares against the sent fragment.

Verified so far (2026-07-17):
- DDS tone -> internal loopback -> RX capture: clean sine on BOTH `.11` and
  `.13`. The radio silicon carries a SIGNAL end to end.
- TX **DMA** data does NOT reach the loopback on this image: the tone (DDS
  internal generator) loops fine, buffer data arrives as zeros, 2ch and 4ch
  layouts alike. The device tree carries `mwipcore@43c00000` -- a MathWorks
  reference design; its fabric likely feeds TX from the mwipcore, not the DDS
  DMA mux. Next levers: drive the mwipcore path, or load the trios BPSK FPGA
  core (specs/fpga/bpsk.t27, merged in the t27 repo) which owns the datapath
  explicitly.

Operational facts that cost time to learn:
- `ensm_mode` can boot as `sleep` (RX DMA times out with "Unable to refill");
  on this driver writing `wait`/`alert`/`fdd` may NOT leave sleep (.12 tonight).
  A board that boots straight into `fdd` (.13) captures immediately.
- COLD power-on frequently leaves the AD9361 dead on SPI (`CHIP_ID 0x0`) or
  garbled (`0xF8`); a WARM `reboot` re-probes with power already stable and has
  repeatedly resurrected the full chain. The radio lottery is a POWER problem.
- `/root` is tmpfs: every reboot erases deployed daemons and probes.
