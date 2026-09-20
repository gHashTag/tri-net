#!/bin/sh
# Push real over-the-air samples through the ternary correlator running in the
# PL, and compare the fabric's answer with the software reference, sample by
# sample. Runs ON THE BOARD, from the UART console.
#
#   ./corr_on_board.sh rx_on_raw.hex golden_matched.txt
#
# The comparison is bit-exact by construction: every ingested sample produces one
# correlator output, and every output is compared with the value the reference
# produced for the same sample. One mismatch fails the run. "Close" is not a
# result here.
#
# Exit codes: 0 all values matched   2 preconditions   3 anchor wrong
#             4 no ingest happening  5 at least one value differs

set -e

SAMPLES="${1:-rx_on_raw.hex}"
GOLDEN="${2:-golden_matched.txt}"
LIMIT="${3:-256}"

DATA_O=0xE000A048        # bank 2 out -> EMIOGPIOO[31:0]
DATA_I=0xE000A068        # bank 2 in  <- EMIOGPIOI[31:0]
DIRM=0xE000A284
OEN=0xE000A288
ANCHOR=18368             # 0x47C0

say() { echo "[$(date -u +%H:%M:%S)] $*"; }

if command -v devmem2 >/dev/null 2>&1; then
    rd() { devmem2 "$1" w | sed -n 's/.*: 0x//p' | tail -1; }
    wr() { devmem2 "$1" w "$2" >/dev/null; }
elif busybox devmem 0 >/dev/null 2>&1; then
    rd() { busybox devmem "$1" 32 | sed 's/^0x//'; }
    wr() { busybox devmem "$1" 32 "$2"; }
else
    say "FATAL: need devmem2 or busybox devmem"; exit 2
fi

[ -f "$SAMPLES" ] || { say "FATAL: no $SAMPLES"; exit 2; }
[ -f "$GOLDEN" ]  || { say "FATAL: no $GOLDEN"; exit 2; }

say "--- checking that our bitstream is live ---"
wr "$DIRM" 0x00FFFFFF
wr "$OEN"  0x00FFFFFF
GOT=$(( 0x$(rd "$DATA_I") & 0xFFFF ))
say "anchor: $GOT (expected $ANCHOR)"
[ "$GOT" = "$ANCHOR" ] || { say "VERDICT: not our bitstream in the fabric"; exit 3; }

# ---- load the 8 ternary taps: matched code sign(cos(2*pi*k/8)) ------------
# 01 -> +1, 10 -> -1, 00 -> 0.   +1 +1 0 -1 -1 -1 0 +1
say "--- loading taps ---"
set -- 1 1 0 2 2 2 0 1
i=0
for TAP in "$@"; do
    BASE=$(( (TAP << 22) | (i << 19) ))
    wr "$DATA_O" $(printf "0x%X" "$BASE")                 # c_wr low, address+data set
    wr "$DATA_O" $(printf "0x%X" $(( BASE | (1 << 18) ))) # rising edge on c_wr
    wr "$DATA_O" $(printf "0x%X" "$BASE")
    i=$(( i + 1 ))
done

# ---- reset the delay line -------------------------------------------------
wr "$DATA_O" 0x00020000
wr "$DATA_O" 0x00000000

# ---- stream the capture ---------------------------------------------------
say "--- streaming $LIMIT samples from $SAMPLES ---"
STROBE=0
N=0
FAIL=0
FIRSTBAD=""
exec 3< "$SAMPLES"
exec 4< "$GOLDEN"
while [ "$N" -lt "$LIMIT" ]; do
    read -r HEXWORD 0<&3 || break
    read -r EXPECT  0<&4 || break
    [ -z "$HEXWORD" ] && continue

    SAMP=$(( 0x$HEXWORD & 0xFFFF ))
    STROBE=$(( 1 - STROBE ))
    wr "$DATA_O" $(printf "0x%X" $(( (STROBE << 16) | SAMP )))

    RAW=$(rd "$DATA_I")
    CORR=$(( ( 0x$RAW >> 16 ) & 0xFFFFF ))
    [ "$CORR" -ge 524288 ] && CORR=$(( CORR - 1048576 ))   # sign-extend 20 bits

    if [ "$CORR" != "$EXPECT" ]; then
        FAIL=$(( FAIL + 1 ))
        [ -z "$FIRSTBAD" ] && FIRSTBAD="sample $N: fabric=$CORR reference=$EXPECT"
    fi
    N=$(( N + 1 ))
done
exec 3<&-
exec 4<&-

COUNT=$(( ( 0x$(rd "$DATA_I") >> 36 ) & 0xFF ))
say "streamed $N samples, fabric ingest counter reports $COUNT (mod 256)"

if [ "$N" -gt 0 ] && [ "$COUNT" = "0" ] && [ "$N" != "256" ]; then
    say "VERDICT: the fabric never counted an ingest. The strobe is not reaching"
    say "  the correlator, or FCLK is not running. Check with load_and_verify.sh."
    exit 4
fi

if [ "$FAIL" -ne 0 ]; then
    say "VERDICT: $FAIL of $N values differ from the reference."
    say "  first: $FIRSTBAD"
    say "  This is a real discrepancy between the fabric and the software model."
    say "  Keep this log: it is worth more than a passing run."
    exit 5
fi

say "--- VERDICT: $N of $N values bit-exact against the software reference ---"
say "Own RTL processed real over-the-air samples in the PL, and the fabric and"
say "the software model agree on every single one."
exit 0
