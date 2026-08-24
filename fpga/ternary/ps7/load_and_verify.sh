#!/bin/sh
# First load of an own bitstream into the Zynq-7020 PL, with verification.
# Runs ON THE BOARD. POSIX sh, no bashisms: the rootfs may be busybox.
#
# READ THIS FIRST
#   This replaces whatever is in the PL right now, which on these boards is the
#   vendor design carrying the AD9361 datapath and PL Ethernet. The board WILL
#   lose network the moment the load succeeds. Run it from the UART console, not
#   over ssh. Nothing on the SD card is touched, so `reboot` restores the vendor
#   bitstream and the radio.
#
# Usage:  ./load_and_verify.sh ps7_probe.bin
#
# Exit codes distinguish the failure modes that otherwise look identical:
#   0 loaded and verified          4 loaded, no clock reaching the fabric
#   2 preconditions not met        5 loaded, clock runs, MAC wrong
#   3 load rejected (format)       6 loaded but a foreign bitstream answered

set -e

BIN="${1:-ps7_probe.bin}"
MGR=/sys/class/fpga_manager/fpga0
GPIO=0xE000A000          # Zynq GPIO controller (UG585 ch. 14)
DATA2=0xE000A048         # bank 2 output data  -> EMIOGPIOO[31:0]
DATA2_RO=0xE000A068      # bank 2 input data   <- EMIOGPIOI[31:0]
DIRM2=0xE000A284         # bank 2 direction
OEN2=0xE000A288          # bank 2 output enable
ANCHOR=0x47C0

say() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ---- a 32-bit poke/peek that works on whatever the image happens to have ----
if command -v devmem2 >/dev/null 2>&1; then
    rd() { devmem2 "$1" w | sed -n 's/.*: 0x//p' | tail -1; }
    wr() { devmem2 "$1" w "$2" >/dev/null; }
elif busybox devmem 0 >/dev/null 2>&1; then
    rd() { busybox devmem "$1" 32 | sed 's/^0x//'; }
    wr() { busybox devmem "$1" 32 "$2"; }
elif command -v python3 >/dev/null 2>&1; then
    rd() { python3 -c "
import mmap,os,struct,sys
a=int(sys.argv[1],16); p=a & ~0xfff; o=a-p
f=os.open('/dev/mem', os.O_RDWR|os.O_SYNC)
m=mmap.mmap(f,4096,offset=p)
print('%08x'%struct.unpack('<I',m[o:o+4])[0])" "$1"; }
    wr() { python3 -c "
import mmap,os,struct,sys
a=int(sys.argv[1],16); v=int(sys.argv[2],16); p=a & ~0xfff; o=a-p
f=os.open('/dev/mem', os.O_RDWR|os.O_SYNC)
m=mmap.mmap(f,4096,offset=p)
m[o:o+4]=struct.pack('<I',v)" "$1" "$2"; }
else
    say "FATAL: need devmem2, busybox devmem or python3 to reach the GPIO block"
    exit 2
fi

# ---------------------------- preconditions --------------------------------
say "--- preconditions ---"
[ -f "$BIN" ] || { say "FATAL: $BIN not found"; exit 2; }
[ -d "$MGR" ] || { say "FATAL: no $MGR; this kernel has no Zynq FPGA manager"; exit 2; }
[ -e /dev/mem ] || { say "FATAL: /dev/mem missing"; exit 2; }
say "fpga manager: $(cat $MGR/name 2>/dev/null), state=$(cat $MGR/state 2>/dev/null)"
say "bitstream   : $BIN, $(wc -c < "$BIN") bytes"
say "NOTE: the PL is about to be replaced. Network on this board will drop."

DMESG_MARK=$(dmesg | wc -l)

# ------------------------------- the load ----------------------------------
say "--- loading ---"
mkdir -p /lib/firmware
cp "$BIN" /lib/firmware/
FW=$(basename "$BIN")
echo "$FW" > "$MGR/firmware" 2>/dev/null || true
sleep 1
STATE=$(cat "$MGR/state" 2>/dev/null || echo unknown)
say "state after load: $STATE"
dmesg | tail -n +"$DMESG_MARK" | grep -i "fpga\|pcap\|zynq" || true

if [ "$STATE" != "operating" ]; then
    say "VERDICT: the manager did not reach 'operating'."
    say "  Most likely the payload orientation is wrong. Retry with the other file:"
    say "    ./load_and_verify.sh ${FW%.bin}.swab.bin"
    say "  If dmesg says 'Timeout waiting for DMA' the stream never synced at all."
    exit 3
fi

# ------------------------- verification over EMIO --------------------------
say "--- verification ---"
wr "$DIRM2" 0x000003FF     # low 10 bits driven by PS toward the PL
wr "$OEN2"  0x000003FF

RAW=$(rd "$DATA2_RO")
GOT_ANCHOR=$(printf "0x%X" $(( 0x$RAW & 0xFFFF )))
say "EMIO read: 0x$RAW   anchor=$GOT_ANCHOR expected=$ANCHOR"

if [ "$GOT_ANCHOR" != "$ANCHOR" ]; then
    say "VERDICT: the fabric answered, but not with our anchor."
    say "  Either an older or foreign bitstream is loaded, or EMIO is not wired"
    say "  as this design expects. Nothing here is damaged; reboot restores the"
    say "  vendor bitstream."
    exit 6
fi
say "anchor OK: our bitstream is in the fabric"

# heartbeat: high bits of a counter on FCLK. Static value means no PL clock.
HB1=$(( ( 0x$(rd "$DATA2_RO") >> 25 ) & 0x7F ))
sleep 1
HB2=$(( ( 0x$(rd "$DATA2_RO") >> 25 ) & 0x7F ))
say "heartbeat: $HB1 -> $HB2"
if [ "$HB1" = "$HB2" ]; then
    say "VERDICT: bitstream loaded but FCLK does not reach the fabric."
    say "  The PS supplies FCLK; if the FSBL never enabled it, or PL level"
    say "  shifters are still down, the design is configured and frozen."
    exit 4
fi
say "clock OK: FCLK is running in the fabric"

# ternary sign-select MAC: 01 -> +x, 10 -> -x, anything else -> 0
FAIL=0
check() {   # check <x> <w> <expected>
    wr "$DATA2" $(printf "0x%X" $(( ($2 << 8) | ($1 & 0xFF) )))
    sleep 1
    Y=$(( ( 0x$(rd "$DATA2_RO") >> 16 ) & 0x1FF ))
    [ "$Y" -gt 255 ] && Y=$(( Y - 512 ))     # sign-extend the 9-bit result
    if [ "$Y" = "$3" ]; then
        say "  MAC x=$1 w=$2 -> $Y   ok"
    else
        say "  MAC x=$1 w=$2 -> $Y   EXPECTED $3"
        FAIL=$(( FAIL + 1 ))
    fi
}
say "ternary MAC vectors:"
check 42  1  42
check 42  2 -42
check 42  0   0
check 42  3   0
check 127 1 127
check 127 2 -127

if [ "$FAIL" -ne 0 ]; then
    say "VERDICT: $FAIL vector(s) wrong. The design is live but computes"
    say "  differently from the software reference. That is a real defect and"
    say "  the interesting one: capture this log."
    exit 5
fi

say "--- VERDICT: loaded, clocked, and bit-exact against the software reference ---"
say "This is the first own bitstream to run in this PL."
say "Run 'reboot' to restore the vendor bitstream and the radio."
exit 0
