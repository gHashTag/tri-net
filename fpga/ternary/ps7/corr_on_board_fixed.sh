#!/bin/sh
# Push real over-the-air samples through the ternary correlator running in the
# PL, and compare the fabric's answer with the software reference.
#
# Fix over corr_on_board.sh: the EMIO input word is 64 bits and Zynq splits it
# across TWO GPIO banks. Bank 2 (0xE000A068) carries EMIOGPIOI[31:0], bank 3
# (0xE000A06C) carries EMIOGPIOI[63:32]. The original script read bank 2 only,
# so:
#   - corr, which lives at [35:16], was truncated to its low 16 bits
#   - count, at [43:36], was read as (32-bit >> 36) == always 0
#   - ack, at [44], was invisible, so the handshake was never observed
#
# Exit codes: 0 all matched  2 preconditions  3 anchor wrong
#             4 no ingest    5 at least one value differs

SAMPLES="${1:-rx_on_raw.hex}"
GOLDEN="${2:-golden_matched.txt}"
LIMIT="${3:-256}"

DATA_O=0xE000A048        # bank 2 out -> EMIOGPIOO[31:0]
DATA_I=0xE000A068        # bank 2 in  <- EMIOGPIOI[31:0]
DATA_I_HI=0xE000A06C     # bank 3 in  <- EMIOGPIOI[63:32]
DIRM=0xE000A284
OEN=0xE000A288
ANCHOR=18368             # 0x47C0

say() { echo "[$(date -u +%H:%M:%S)] $*"; }

if busybox devmem 0 >/dev/null 2>&1; then
    rd() { busybox devmem "$1" 32 | sed 's/^0x//'; }
    wr() { busybox devmem "$1" 32 "$2"; }
else
    say "FATAL: need busybox devmem"; exit 2
fi

[ -f "$SAMPLES" ] || { say "FATAL: no $SAMPLES"; exit 2; }
[ -f "$GOLDEN" ]  || { say "FATAL: no $GOLDEN"; exit 2; }

say "--- checking that our bitstream is live ---"
wr "$DIRM" 0x00FFFFFF
wr "$OEN"  0x00FFFFFF
LO=$(rd "$DATA_I"); HI=$(rd "$DATA_I_HI")
GOT=$(( 0x$LO & 0xFFFF ))
say "bank2=0x$LO  bank3=0x$HI"
say "anchor: $GOT (expected $ANCHOR)"
[ "$GOT" = "$ANCHOR" ] || { say "VERDICT: anchor wrong, not our bitstream"; exit 3; }

# ---- helper: assemble the 20-bit signed correlator output from both banks ----
read_corr() {
    L=$(rd "$DATA_I"); H=$(rd "$DATA_I_HI")
    C=$(( ((0x$H & 0xF) << 16) | ((0x$L >> 16) & 0xFFFF) ))
    [ "$C" -ge 524288 ] && C=$(( C - 1048576 ))
    echo "$C"
}
read_count() { H=$(rd "$DATA_I_HI"); echo $(( (0x$H >> 4) & 0xFF )); }
read_ack()   { H=$(rd "$DATA_I_HI"); echo $(( (0x$H >> 12) & 1 )); }

say "--- settle: PL reset is still moving right after configuration ---"
# Measured: for roughly the first eight sample pushes after the bitstream lands,
# core_rst asserts spontaneously and the ingest counter restarts (1,2,3,4,
# 1,2,3,4, then clean). The taps survive it - they have no reset - but the
# delay line does not, so any run started immediately is silently restarted
# mid-stream. Push throwaway samples until the counter advances monotonically
# over a whole window, and only then load taps and stream.
SETTLED=0
TRY=0
while [ "$TRY" -lt 12 ]; do
    PREVC=$(read_count)
    MONO=1
    k=0
    while [ "$k" -lt 8 ]; do
        SB=$(( 1 - ${SB:-0} ))
        wr "$DATA_O" $(printf "0x%X" $(( (SB << 16) | 1 )))
        NOWC=$(read_count)
        EXP=$(( (PREVC + 1) % 256 ))
        [ "$NOWC" != "$EXP" ] && MONO=0
        PREVC=$NOWC
        k=$(( k + 1 ))
    done
    TRY=$(( TRY + 1 ))
    if [ "$MONO" = "1" ]; then SETTLED=1; break; fi
done
say "settle: $([ "$SETTLED" = 1 ] && echo "clean after $TRY window(s)" || echo "NEVER SETTLED in $TRY windows")"
[ "$SETTLED" = "1" ] || { say "VERDICT: PL reset never stopped asserting; not a numerical result"; exit 4; }

say "--- reset the delay line FIRST ---"
# Reset before the taps, not after: c_wr is edge-detected two flops downstream
# of an asynchronous PS write, and the first transaction after the bitstream
# lands is the one that gets missed. Measured: tp0 stayed 0 while tp1..tp7 all
# took their values, which is exactly one lost rising edge on c_wr.
wr "$DATA_O" 0x00020000
wr "$DATA_O" 0x00000000

say "--- loading taps: matched = 1 1 0 -1 -1 -1 0 1 ---"
# tap code: 01 -> +1, 10 -> -1, 00/11 -> 0
# Each tap is written TWICE. The write is idempotent (same address, same data),
# so a duplicated transaction costs nothing and covers a dropped edge.
set -- 1 1 0 2 2 2 0 1        # encoded c_data per tap index 0..7
for PASS in 1 2; do
    i=0
    for CODE in "$@"; do
        BASE=$(( (CODE << 22) | (i << 19) ))
        wr "$DATA_O" $(printf "0x%X" "$BASE")
        wr "$DATA_O" $(printf "0x%X" $(( BASE | (1 << 18) )))
        wr "$DATA_O" $(printf "0x%X" "$BASE")
        i=$(( i + 1 ))
    done
    say "   tap pass $PASS done"
done

say "--- reset the delay line again, taps survive it ---"
wr "$DATA_O" 0x00020000
wr "$DATA_O" 0x00000000

COUNT0=$(read_count)
say "ingest counter before streaming: $COUNT0"

say "--- streaming $LIMIT samples ---"
# Pipeline offset: m_data is registered off s_valid and corr_hold is registered
# off m_valid, so the value readable after pushing sample n is the correlation
# through sample n-1. Compare each read against the PREVIOUS golden value and
# take one extra read at the end. Verified by hand on the first six samples:
#   golden[1] = tp0*s1 + tp1*s0 = -54 + 6 = -48, which is what the fabric shows.
STROBE=0
N=0
CHECKED=0
FAIL=0
FIRSTBAD=""
PREV_EXPECT=""
exec 3< "$SAMPLES"
exec 4< "$GOLDEN"
while [ "$N" -lt "$LIMIT" ]; do
    read -r HEXWORD 0<&3 || break
    read -r EXPECT  0<&4 || break
    [ -z "$HEXWORD" ] && continue

    SAMP=$(( 0x$HEXWORD & 0xFFFF ))
    STROBE=$(( 1 - STROBE ))
    wr "$DATA_O" $(printf "0x%X" $(( (STROBE << 16) | SAMP )))

    CORR=$(read_corr)
    if [ -n "$PREV_EXPECT" ]; then
        CHECKED=$(( CHECKED + 1 ))
        if [ "$CORR" != "$PREV_EXPECT" ]; then
            FAIL=$(( FAIL + 1 ))
            [ -z "$FIRSTBAD" ] && FIRSTBAD="index $(( N - 1 )): fabric=$CORR reference=$PREV_EXPECT"
        fi
    fi
    PREV_EXPECT="$EXPECT"
    N=$(( N + 1 ))
done
exec 3<&-
exec 4<&-

# the last sample's result needs one more read, with no write in between
if [ -n "$PREV_EXPECT" ]; then
    CORR=$(read_corr)
    CHECKED=$(( CHECKED + 1 ))
    if [ "$CORR" != "$PREV_EXPECT" ]; then
        FAIL=$(( FAIL + 1 ))
        [ -z "$FIRSTBAD" ] && FIRSTBAD="index $(( N - 1 )): fabric=$CORR reference=$PREV_EXPECT"
    fi
fi

COUNT1=$(read_count)
INGESTED=$(( (COUNT1 - COUNT0 + 256) % 256 ))
say "streamed $N samples; ingest counter $COUNT0 -> $COUNT1 (delta $INGESTED mod 256)"

if [ "$INGESTED" = "0" ] && [ "$N" -gt 0 ] && [ "$FAIL" = "$CHECKED" ]; then
    say "VERDICT: the fabric ingested nothing. The strobe is not reaching the"
    say "  delay line, or the taps never loaded. Not a numerical defect."
    exit 4
fi

if [ "$FAIL" -ne 0 ]; then
    say "VERDICT: $FAIL of $CHECKED compared values differ from the reference."
    say "  first: $FIRSTBAD"
    exit 5
fi

say "--- VERDICT: $CHECKED of $CHECKED values bit-exact against the software reference ---"
say "The ternary correlator ran in the fabric on real over-the-air samples."
exit 0
