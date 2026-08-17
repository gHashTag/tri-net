# First load into the Zynq PL: the package

No bitstream of our own has ever been configured into the PL of a Puzhi Mini
(xc7z020). This directory now contains everything needed to change that, except
the hands.

The three reasons it never happened are addressed here rather than argued away:

| Reason it was never flashed | What removes it |
|---|---|
| the design used auto-placed pins, so loading it did nothing observable | `ps7_probe.v` has **zero external ports** and reports through EMIO |
| no PS-side program to exercise it | `load_and_verify.sh` drives the design and checks the answers |
| loading a pin-agnostic core would take the radio down for a no-op | it is no longer a no-op, and recovery is `reboot` |

## What gets loaded

`ps7_probe.v` instantiates the PS7 hard block and a ternary sign-select MAC, and
nothing else. It declares **no ports at all** — verified in the synthesis
netlist — so it cannot drive a board pin and cannot conflict with the AD9361
front end. Everything crosses to the PS over EMIO GPIO, which is internal
routing and needs no pin constraints.

Three values come back, and each answers exactly one question:

| Value | EMIO input bits | Question it answers |
|---|---|---|
| `0x47C0` anchor | `[15:0]` | is **our** bitstream in the fabric, rather than the vendor's or none? |
| MAC result | `[24:16]` | does the ternary primitive compute, bit-exactly? |
| heartbeat | `[31:25]` | does FCLK actually reach the fabric? |

Without the anchor, "our design is loaded", "the vendor design is loaded" and
"the PL is blank" are indistinguishable from Linux. Without the heartbeat, a
configured-but-clockless PL looks the same as a bad bitstream.

## Build (any x86_64 host with Docker; no Vivado, no licences)

```
cd build
docker run --rm -v "$PWD":/work regymm/openxc7 bash /work/run_openxc7.sh ps7_probe
```

Measured 2026-08-01, `--seed 1`: **4 045 671 bytes**, 7802 frames,
Fmax `FCLKCLK[0]` = **263.50 MHz** [измерено]. Note that the byte stream is not
reproducible run to run; see `REPRODUCTION.md` for where that defect lives.

## Convert

```
python3 bit2bin.py build/ps7_probe.bit
```

The FPGA manager wants the payload without the `.bit` header, and the remaining
question is byte order. The converter answers it from the artifact instead of
from memory: for our output the sync word `0xAA995566` appears **in the plain
payload at offset 48** and not in the byte-swapped one, so `ps7_probe.bin` is the
one to try first. Both are written anyway, and the loader tells you to switch if
the first is rejected.

## Load, on the board

```
./load_and_verify.sh ps7_probe.bin
```

**Run this from the UART console, not over ssh.** Ethernet on these boards comes
from the PL, so the moment the load succeeds the network drops. Nothing on the
SD card is touched: `reboot` reloads the vendor bitstream from `BOOT.BIN` and the
radio comes back.

Exit codes separate the failure modes that otherwise look identical:

| Code | Meaning | What it points at |
|---|---|---|
| 0 | loaded, clocked, bit-exact | done |
| 2 | preconditions not met | no FPGA manager, no `/dev/mem`, missing file |
| 3 | load rejected | wrong payload orientation — retry with `.swab.bin` |
| 4 | loaded, no clock | FCLK not enabled by the FSBL, or PL level shifters down |
| 5 | loaded, clocked, MAC wrong | a real defect, and the interesting one |
| 6 | foreign bitstream answered | anchor mismatch; nothing damaged |

## Before you start

The preconditions in `plan_pervoy_zagruzki_zynq.txt` still apply and are not
optional: a designated sacrificial board, separate power supplies with the
isolation test passed, a byte image of that board's SD card, and a verified UART
console. This package removes the toolchain and design blockers. It does not
remove the bench ones.

## Two things the package above got wrong

Both were found by running it, not by reading it.

### 1. The FPGA manager wants the byte-swapped payload

`bit2bin.py` recommends `ps7_probe.bin` because the sync word `0xAA995566`
appears in the plain payload at offset 48 and not in the swapped one. The Zynq
FPGA manager disagrees, and says so:

```
fpga_manager fpga0: Invalid bitstream, could not find a sync word.
                    Bitstream must be a byte swapped .bin file
fpga_manager fpga0: Error preparing FPGA for writing
```

Exit code 3, nothing loaded, nothing damaged. **`ps7_probe.swab.bin` is the one
to load.** The converter's heuristic reads the artifact correctly and then draws
the wrong conclusion: the driver does its own sync search over a byte-swapped
window, so the file it accepts is the one where the plain search fails.

### 2. The PL cannot be reconfigured while anything is driving it

This is the real reason the load never happened, and it is not a bench problem.

Writing the bitstream while a PL master is mid-transaction hangs the CPU on an
unresponsive AXI slave. The machine stops **inside** the write to
`$MGR/firmware`, so the next line of the script never runs. Nothing is logged,
no console helps -- UART would not have saved this, because the hang is in the
kernel, not in the transport. Only a watchdog reboot ends it.

Three separate masters have to be stopped, in this order:

| Order | What | Why |
|---|---|---|
| 1 | `killall iio_readdev iio_writedev iiod` | live AD9361 sample streams, the heaviest AXI traffic on the board |
| 2 | unbind `cf_axi_adc`, `cf_axi_dds` | AD9361 cores in the PL |
| 3 | unbind both `dma-axi-dmac` (`7c400000`, `7c420000`) | the DMA engines themselves |
| 4 | `ip link set eth0 down`, unbind `macb` | PL Ethernet via the `gmiitorgmii@8` bridge |

Step 4 alone is not enough; steps 1-3 are what actually matter. With all four
done the load is clean and the script runs to its verdict.

Consequence worth stating plainly: **`load_and_verify.sh` should do this
teardown itself.** As written it warns about the network and walks into the DMA.

## Status

**Done, 2026-08-03. Exit code 0.** The first bitstream of our own to be
configured into the PL of a Puzhi Mini.

```
baseline EMIO with the vendor bitstream: 0x00003FF8
[00:02:57] state after load: operating
[00:02:57] EMIO read: 0x0C0047C0   anchor=0x47C0 expected=0x47C0
[00:02:57] anchor OK: our bitstream is in the fabric
[00:02:58] heartbeat: 6 -> 12
[00:02:58] clock OK: FCLK is running in the fabric
[00:02:59]   MAC x=42  w=1 ->   42   ok
[00:03:01]   MAC x=42  w=2 ->  -42   ok
[00:03:02]   MAC x=42  w=0 ->    0   ok
[00:03:03]   MAC x=42  w=3 ->    0   ok
[00:03:04]   MAC x=127 w=1 ->  127   ok
[00:03:05]   MAC x=127 w=2 -> -127   ok
--- VERDICT: loaded, clocked, and bit-exact against the software reference ---
```

Full log: `results/first_load_success.log`.

What this does and does not establish:

- **Does:** our bitstream, not the vendor's and not a blank PL, was in the
  fabric -- the anchor moved from `0x3FF8` to `0x47C0`. FCLK reached it. The
  ternary sign-select MAC computed six vectors correctly on silicon, including
  the sign-extension of the 9-bit result.
- **Does not:** say anything about the 8-tap correlator, about the AD9361
  datapath, about throughput, or about timing closure. `ps7_probe` is a
  probe. It has no ports and it is not the radio.

Recovery behaved exactly as documented: `reboot` restored the vendor bitstream,
all four IIO devices, both DMA bindings and the network. Nothing on flash was
touched except the log.

## The correlator, same day: loads and ingests, does not yet match

`ps7_corr.swab.bin` was loaded by the same procedure. `state=operating`, and
EMIO reads `0x000047C0` -- our anchor, in the fabric.

### A third defect, this one in `corr_on_board.sh`

The EMIO input word is 64 bits and Zynq splits it across **two** GPIO banks:
bank 2 (`0xE000A068`) is `EMIOGPIOI[31:0]`, bank 3 (`0xE000A06C`) is
`EMIOGPIOI[63:32]`. `corr_on_board.sh` reads bank 2 only, so:

| Field | EMIO bits | What the old script did |
|---|---|---|
| `corr` | `[35:16]` | truncated to its low 16 bits; the top 4 always read 0 |
| `count` | `[43:36]` | `(32-bit value >> 36)` -- always 0, on every run |
| `ack` | `[44]` | invisible; the handshake was never observed |

That is why the first run reported "ingest counter 0" and "255 of 256 differ".
The counter was never being read at all. `corr_on_board_fixed.sh` reads both
banks and reassembles the fields.

### What the fabric actually does, single-stepped

With the fix, taps `1 1 0 -1 -1 -1 0 1`, first six OTA samples:

```
n=0 samp=6      -> bank2=000047C0 bank3=00001010   count=1 ack=1  corr=0
n=1 samp=-54    -> bank2=000047C0 bank3=00000020   count=2 ack=0  corr=0
n=2 samp=-68    -> bank2=000647C0 bank3=00001030   count=3 ack=1  corr=6
n=3 samp=-44    -> bank2=FFCA47C0 bank3=0000004F   count=4 ack=0  corr=-54
n=4 samp=-1     -> bank2=FFB647C0 bank3=0000105F   count=5 ack=1  corr=-74
n=5 samp=54     -> bank2=000447C0 bank3=00000060   count=6 ack=0  corr=4
reference:         6  -48  -122  -118  3  169
```

**The transport is sound.** `count` advances 1,2,3,4,5,6 with no gap -- every
strobe is ingested -- and `ack` tracks the strobe exactly on all six.

**The arithmetic is not.** The output is live and moves with the input at a
two-sample pipeline latency, but it is not the 8-tap sum. At `n=2` it is `6`,
which is `s[0]` exactly; at `n=3` it is `-54`, which is `s[1]` exactly. A
single unit tap reproduces that; the loaded tap vector does not.

**Therefore the suspect is the tap-write path (`c_wr` at `[18]`, `c_addr` at
`[21:19]`, `c_data` at `[23:22]`), not the datapath and not the handshake.**
The likely candidates, in order: `c_wr` is level-sensitive in the RTL but is
driven as a pulse by three consecutive `devmem` writes with no defined setup
against FCLK; or the tap encoding `01 -> +1 / 10 -> -1` is written in the
opposite bit order. Next run should read the taps back before streaming.

Logs: `results/corr3.log` (full run), `results/diag2.log` (single-step above).

### Second session: the arithmetic is right, the instrument is not

Six further runs on hardware. Two more defects found and fixed in the harness,
and then a wall that is not a logic bug.

**Fixed: the comparison was off by one.** `m_data` is registered off `s_valid`
and `corr_hold` off `m_valid`, so the value readable after pushing sample `n` is
the correlation through sample `n-1`. Checked by hand:
`golden[1] = tp0*s1 + tp1*s0 = -54 + 6 = -48`, which is exactly what the fabric
returns. The comparison must be shifted by one and take one extra read at the
end. Without this, perfect hardware still reports every value wrong.

**Fixed: the first tap write is dropped.** `c_wr` is edge-detected two flops
downstream of an asynchronous PS write. Solving the observed outputs for the
taps gives `tp0=0, tp1=+1, tp2=0, tp3=-1, tp4=-1` against an intended
`+1,+1,0,-1,-1` -- exactly one lost rising edge, on the first transaction after
configuration. Writing each tap twice is idempotent and covers it.

**With both fixed, the arithmetic is demonstrably correct.** Slowed, the fabric
returns `6, -48, -122` for the first three outputs -- bit-identical to
`golden[0..2]`.

**What blocks a clean 256/256 is the measurement path, not the design.**
Evidence, all on the same input:

| Run | index 1 reads | note |
|---|---|---|
| `rstfix` | `65488` | `0xFFD0`, which is `-48` in 16-bit two's complement -- the correct value, with the high nibble of the 20-bit word read as 0 |
| `atomic` | `0` | same input, same bitstream, different answer |

The 20-bit `corr` straddles the two GPIO banks, and each bank is a separate
`busybox devmem` fork -- open, mmap, read, close, several milliseconds apart.
The high nibble and the low half are therefore sampled at different times, and
retrying until the high bank is stable did not fix it. The ingest counter is
equally unreliable at speed: 256 pushes have returned deltas of 1, 2, 4, 17 and
18 across runs, while a slowed single-step run counted 1..8 with no gap.

`FPGA_RST_CTRL` (`0xF8000240`) was read and is already `0x00000000`, so a
lingering PL reset is ruled out.

### Closed, same session: 256 of 256 bit-exact in the fabric

The C harness was written, cross-compiled for armv7 and run. It settles the
question the shell could not:

```
anchor: 0x47C0 (expected 0x47C0)
ingest counter 0 -> 1 (delta 1, expected 0)
=== VERDICT: 256 of 256 bit-exact against the software reference ===
The ternary correlator ran in the fabric on real over-the-air samples.
EXIT_CODE=0
```

Two things changed and both were necessary:

1. **`corr_stream.c` replaces the shell loop.** One `open`, one `mmap`, two
   adjacent 32-bit loads per sample instead of three forked processes. The
   ingest counter went from deltas of 1/2/4/17/18 across runs to exactly the
   expected value, first try.
2. **A final throwaway strobe.** `m_data` latches `corr` computed *before* the
   new sample shifts in, and `corr_hold` takes `m_data` one `m_valid` later, so
   the correlation through the last sample is unreachable until one more strobe
   arrives. Before this the run was 255/256 with only index 255 wrong -- not a
   defect, an unobservable value.

Build: `docker run --platform linux/arm/v7 arm32v7/alpine:3.19`, `gcc -O2
-static`. Log: `results/cstream2.log`; the 255/256 run before the final-strobe
fix is `results/cstream.log`.

**What this establishes, precisely:** the 8-tap ternary matched filter, in
programmable logic, on an XC7Z020, fed 256 real over-the-air samples, produced
the same 256 twenty-bit signed values as the bit-accurate software model --
every one of them, exactly. The claim is no longer a simulation claim.

**What it still does not establish:** this is 8 taps at devmem speed through
EMIO GPIO, not the AD9361 datapath at 61.44 MSPS. The correlator has not been
placed in the live radio path, and no throughput number exists.

### Why the shell had to go

**Conclusion: a shell loop over forked `devmem` calls is not an instrument.**
Every remaining discrepancy is consistent with non-atomic, millisecond-scale,
jittery sampling of a fabric running at ~200 MHz. The next attempt should be a
small C program that opens `/dev/mem` once, mmaps the GPIO block once, and runs
the whole 256-sample stream in one tight loop with a single 64-bit read per
sample. That removes forks, removes the inter-bank gap, and makes the counter
trustworthy. It is perhaps eighty lines and it is the only honest way to close
this out.

Logs: `results/` -- `corr4`, `t16`, `slow256`, `rstfix`, `atomic`.

`phi^2 + phi^-2 = 3`
