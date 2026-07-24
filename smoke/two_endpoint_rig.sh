#!/usr/bin/env bash
# two_endpoint_rig.sh — a REAL two-process video call on one Mac, for HONEST end-to-end
# measurement. Single-process loopback confounds every metric (sent and recv are the same
# node's counters; jitter==0 can mean "no stream", not "clean link" — the broken-ruler traps
# that bit waves #24, #26, #33, #37). Here two independent TriNetMonitor instances dial each
# other over real UDP (INVITE bypassed via TRINET_AUTOCALL), each writes its own log, and we
# read the CROSS-process delivery: A->B = (B received) / (A sent).
#
# Enabled by three env hooks (all no-ops in a shipping run):
#   TRINET_LOG=<path>          per-instance log file (LogBus)
#   TRINET_LISTEN=<port>       this instance's UDP listen port
#   TRINET_AUTOCALL=host:port  auto-dial a 1-1 call to the peer on launch
#
# Usage:  smoke/two_endpoint_rig.sh [seconds] [dropPercentOnB]
set -u
SECS="${1:-30}"
DROP="${2:-0}"
APP=/Applications/TriNetMonitor.app
A=/tmp/rigA.log; B=/tmp/rigB.log
pkill -9 -f "TriNetMonitor.app/Contents/MacOS" 2>/dev/null; sleep 2
defaults delete com.trinet.monitor trinetRoom 2>/dev/null   # open lobby: both instances share the empty room
rm -f "$A" "$B"

echo "launching A (:8000) <-> B (:8100)${DROP:+, ${DROP}% induced loss on B}"
open -n --env TRINET_LOG="$A" --env TRINET_LISTEN=8000 --env TRINET_AUTOCALL=127.0.0.1:8100 "$APP"
sleep 1
open -n --env TRINET_LOG="$B" --env TRINET_LISTEN=8100 --env TRINET_AUTOCALL=127.0.0.1:8000 ${DROP:+--env TRINET_DROP=$DROP} "$APP"

END=$(( $(date +%s) + SECS )); while [ "$(date +%s)" -lt "$END" ]; do sleep 5; done

# Last STATS line from each: "video sent=<framesSent> recv=<framesReceived>"
read AS AR < <(grep -aoE "video sent=[0-9]+ recv=[0-9]+" "$A" 2>/dev/null | tail -1 | grep -oE "[0-9]+" | tr '\n' ' ')
read BS BR < <(grep -aoE "video sent=[0-9]+ recv=[0-9]+" "$B" 2>/dev/null | tail -1 | grep -oE "[0-9]+" | tr '\n' ' ')
pkill -9 -f "TriNetMonitor.app/Contents/MacOS" 2>/dev/null

echo
if [ -z "${AS:-}" ] || [ -z "${BR:-}" ]; then
  echo "RIG FAILED — no STATS in one log (call did not establish). Tail of A/B:"
  tail -3 "$A" 2>/dev/null; echo "---"; tail -3 "$B" 2>/dev/null
  exit 1
fi
echo "A sent $AS video, recv $AR   |   B sent $BS video, recv $BR"
python3 -c "print(f'A->B video delivery = {100*$BR/max(1,$AS):.1f}%  (B received / A sent)')"
python3 -c "print(f'B->A video delivery = {100*$AR/max(1,$BS):.1f}%  (A received / B sent)')"
echo "(cross-process ratios — the honest end-to-end numbers a single loopback process cannot give)"
