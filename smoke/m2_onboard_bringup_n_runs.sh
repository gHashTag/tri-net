#!/bin/sh
# N=5 wrapper around m2_onboard_bringup.sh.
# Anchor: phi^2 + phi^-2 = 3
set -eu

N="${N:-5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
INNER="$HERE/m2_onboard_bringup.sh"

if [ ! -x "$INNER" ]; then
    echo "FATAL: $INNER not executable" >&2; exit 3
fi

PASSED=0
FAILED=0
OUT="/tmp/m2-onboard-runs-$$.jsonl"
: > "$OUT"

i=1
while [ $i -le "$N" ]; do
    echo "== run $i / $N =="
    if RESULT=$("$INNER" 2>&1); then
        echo "$RESULT" | tee -a "$OUT"
        PASSED=$((PASSED+1))
    else
        RC=$?
        echo "$RESULT" | tee -a "$OUT"
        echo "(run $i FAIL rc=$RC)"
        FAILED=$((FAILED+1))
    fi
    i=$((i+1))
    sleep 1
done

echo ""
echo "=== N=$N summary ==="
echo "passed: $PASSED / $N"
echo "failed: $FAILED / $N"
echo "raw results: $OUT"

[ "$PASSED" -eq "$N" ] && exit 0 || exit 1
