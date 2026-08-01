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

## Status

Everything above is built and checked off-board. **Nothing here has been run on
hardware.** The moment it is, the result belongs in this file, including a
negative one.

`phi^2 + phi^-2 = 3`
