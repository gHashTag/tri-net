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


## OTA byte transfer: link yes, bytes SNR-blocked without antennas

Followed the tone milestone with a carrier-offset-tolerant FSK modem
(`ota_demod.py`): marker-clocked 3-FSK on TX (marker 100k / bit0 300k / bit1
600k via the DDS), demod by per-window mean instantaneous frequency from I/Q
phase increments, auto-locating the three received tones (signed frequency, so a
common carrier offset preserves marker<0<1 ordering -- no carrier recovery loop
needed).

Real .13 -> .12 capture, 1-byte payload 0x08, 2.5 MSPS:
- The FSK tones ARE present over the air but SNR-starved: strongest received
  line is the receiver's DC/LO-leakage spike (~23); the actual FSK tone sits at
  ~4, near the noise floor. Narrowband energy detection over a long average
  lifts a tone above noise (this is how the LINK was confirmed, 3->98), but
  per-0.3s-symbol demod needs the tone well above noise per window, and it is
  not. Decoded 0 bits.
- Root cause: OPEN SMA ports (no antennas) -- only leakage coupling. This is a
  hardware SNR wall, not a demod bug. Per debugging discipline: do NOT tune
  thresholds around it.

Unblocks, in order of value:
1. Antennas on the TX/RX SMA ports (2.4 GHz whip, SMA male). Raises received
   power by tens of dB -- the same modem should then decode.
2. mwipcore/FPGA TX datapath: a strong, sample-accurate modulated signal instead
   of weak shell-toggled DDS tones -- fixes both SNR and timing jitter at once.

TX toggler (busybox sh, recorded here per no-shell-scripts hook):

    A() { iio_attr -q -c cf-ad9361-dds-core-lpc "$1" "$2" "$3" >/dev/null 2>&1; }
    echo 0 > /sys/kernel/debug/iio/iio:device0/loopback     # real emission
    echo -10 > /sys/bus/iio/devices/iio:device0/out_voltage0_hardwaregain
    A altvoltage0 scale 0.9; A altvoltage1 scale 0.9
    M=100000; Z=300000; O=600000
    for p in 1 2 3; do A altvoltage0 frequency $M; A altvoltage1 frequency $M; sleep 0.3; done
    BITS=$(cat /tmp/otx_bits.txt); i=0
    while [ $i -lt ${#BITS} ]; do
      b=$(echo "$BITS" | cut -c$((i+1)))
      A altvoltage0 frequency $M; A altvoltage1 frequency $M; sleep 0.3
      [ "$b" = "1" ] && F=$O || F=$Z
      A altvoltage0 frequency $F; A altvoltage1 frequency $F; sleep 0.3
      i=$((i+1))
    done
    A altvoltage0 scale 0.0; A altvoltage1 scale 0.0


## CORRECTION: antennas ARE present, link is STRONG, the earlier "SNR wall" was mine

The user confirmed each board has two antennas (TX + RX). Re-measured with a
STEADY tone at full TX power (0 dB atten):

    RX RMS 615, peak sample 1111 (no clip), received tone magnitude 202 at -2.5 MHz

That is a STRONG over-the-air link, not the "SNR wall" reported above. Two of my
own mistakes made it look weak before:
1. Sample rate 2.5 MSPS -> Nyquist +-1.25 MHz, but the two crystals differ by
   ~3 MHz, so the received tone landed at -2.5 MHz and ALIASED out of band.
   Fixed by capturing at 7.68 / 30.72 MSPS so the offset tone stays in band.
2. TX at -10 dB attenuation; full power (0 dB) is ~10 dB louder.

So NO attenuator and NO distance are needed -- antennas + close together is the
strong, easy case. (Distance/attenuation only matter for a direct cable, to
protect RX, or for a real range test.)

Bytes over the air still did NOT decode cleanly, but the cause is now isolated to
the MODULATOR, not the link: shell `iio_attr` frequency toggling is slow and
glitchy, so the FSK symbols are not clean, and the receiver's DC/LO-leakage spike
dominates any window near baseband. The strong steady tone proves the channel; a
clean modulator (DMA/FPGA sample-accurate keying, or at least a DDS driven with
a proper frequency plan away from DC) is what remains. Chasing the shell-FSK
demod further is the spiral the doctrine warns against -- stopped.

Practical settings that worked for the strong steady tone (leave these for the
next attempt): TX atten 0 dB, DDS scale 0.9, RX manual gain ~48-53 dB, sample
rate >= 7.68 MSPS, and MASK +-250 kHz around DC in any tone search.


## Measured: the shell-toggled DDS is the modulator wall (not the link, not the plan)

Retried bytes with tones placed so the RECEIVED FSK lines land >1 MHz from DC
(TX 1000/1500/2000 kHz -> received ~-2.0/-1.5/-1.0 MHz at the ~-3 MHz offset),
manual RX gain 50, 7.68 MSPS. Still no clean decode. The tell: the marker tone
during FSK toggling reads magnitude ~12, versus ~202 for a STEADY DDS tone at
the same power -- a ~16x drop. Re-writing the DDS `frequency` attribute every
0.35s does not produce a clean settled tone (likely a scale/enable glitch per
write). So the modulator, not the channel or the frequency plan, is the wall.
The fix is sample-accurate keying: the DMA/FPGA TX path. DATA_SEL already flips
to 0x2 (DMA) during a buffer write, but the DMA stream does not reach the fabric
TX on this MathWorks image -- that is an FPGA BITSTREAM change (load the ADI
reference DMA-to-TX path, or the t27 BPSK core), not a runtime register poke.
