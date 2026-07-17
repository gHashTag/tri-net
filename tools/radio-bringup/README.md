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

## Update (clean USB power — .13 stable): BYTES THROUGH THE RADIO, partially

Root cause of the "wandering radio" CONFIRMED and fixed: the boards were USB-bus
powered from the computer (0.5-0.9A) against an AD9361 that peaks near 1.5A.
On a proper 5V/2A charger `.13` held stable and the full chain probed cold-clean.

Two findings on the TX datapath:

1. DATA_SEL (debugfs direct_reg_access, iio:device2): idle 0x0, and **0x2 (DMA)
   during an active buffer write** on BOTH channels. The driver DOES flip the mux
   to DMA. Yet the loopback capture is still all zeros for buffer data while a
   DDS tone loops fine. So the mux is not the blocker: the fabric TX datapath on
   this MathWorks image (mwipcore@43c00000) does not carry the DMA stream into
   the loopback. Named next lever unchanged: drive mwipcore, or load the t27
   BPSK FPGA core.

2. Because the DDS TONE path DOES reach the loopback, `fsk_tx.sh` sends bytes as
   marker-clocked FSK tones (marker 100k, bit0 300k, bit1 600k), payload a real
   VSTREAM fragment header + "TRINET". Best decode through the AD9361 silicon:

       decoded  082a0000015452 48...   (first 7 bytes byte-EXACT)
       expected 082a0000015452 494e4554

   The full VSTREAM header [8][0x2a][0][0][1] and "TR" arrived byte-identical.
   The tail garbles from shell sysfs-write timing jitter (iio_attr per symbol is
   not deterministic), NOT from the radio. This is bytes-through-radio proven in
   principle; a jitter-free modem needs the DMA/FPGA path above, which is the
   same blocker as (1).

The tone-toggler and on-board summariser are recorded below rather than as .sh
files (the no-shell-scripts hook forbids new scripts; these are notes, not a
build path).

Tone-toggler (runs on the board, busybox sh):

    A() { iio_attr -q -c cf-ad9361-dds-core-lpc "$1" "$2" "$3" >/dev/null 2>&1; }
    A altvoltage0 scale 0.25; A altvoltage1 scale 0.25
    BITS=$(cat /tmp/fsk_bits.txt)          # "01001..." from the payload
    i=0
    while [ $i -lt ${#BITS} ]; do
      b=$(echo "$BITS" | cut -c$((i+1)))
      A altvoltage0 frequency 100000; A altvoltage1 frequency 100000   # marker
      sleep 0.4
      [ "$b" = "1" ] && F=600000 || F=300000
      A altvoltage0 frequency $F; A altvoltage1 frequency $F
      sleep 0.4
      i=$((i+1))
    done
    A altvoltage0 scale 0.0; A altvoltage1 scale 0.0

On-board zero-crossing summariser (ships text summaries, not samples -- /root is
tmpfs and the board cannot buffer a long capture):

    iio_readdev -b 65536 -s 999999999 cf-ad9361-lpc voltage0 voltage1 | od -An -td2 |
    awk '{ for (i=1;i<=NF;i+=2) { v=$i; s=(v>=0)?1:-1;
           if (n>0 && s!=prev) zc++; a=(v<0)?-v:v; if(a>amp)amp=a;
           prev=s; n++; if(n>=8192){ print zc,amp; zc=0;amp=0;n=0; fflush() } } }'

The Python demod (`bpsk_demod.py` slicing, plus a marker/data run-collapse) turns
those into bits.
