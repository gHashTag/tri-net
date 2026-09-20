#!/usr/bin/env bash
# dispatcher_parity.sh — guard against the class of bug that made Mac group calls
# silent (a subtype handler present in one receive path, missing from its sibling).
#
# There are FOUR receive dispatchers, split by platform x call-mode:
#   Mac  1-1   : CallManager.swift  transport.onReceive
#   Mac  group : CallManager.swift  transport.onReceiveFrom
#   iOS  1-1   : ViewModel.swift     transport.onData
#   iOS  group : ViewModel.swift     transport.onDataFrom
# Every CORE call subtype below MUST be handled in all four. Path-specific extras
# (e.g. the iOS-only RTI SLEW 0xFD 0x53) are intentionally NOT required everywhere.
#
# Exit 0 = parity holds; exit 1 = a core subtype is missing from some dispatcher.
set -u
cd "$(dirname "$0")/.." || exit 2
MAC="phone/desktop/TriNetVideo/CallManager.swift"
IOS="phone/TriNetVideo/ViewModel.swift"

# CORE subtypes that must exist in ALL four dispatchers (label|grep-pattern).
CORE=(
  "0xFC PLI|data\[0\] == 0xFC"
  "0xFD 0xAD audioPCM|data\[0\] == 0xFD, data\[1\] == 0xAD"
  "0xFD 0xBE BWE|data\[0\] == 0xFD, data\[1\] == 0xBE"
  "0xFD 0xC0 audioOpus|data\[0\] == 0xFD, data\[1\] == 0xC0"
  "0xFB 0xCA chat|data\[0\] == 0xFB, data\[1\] == 0xCA"
  "0xFE 0xAC reaction|data\[0\] == 0xFE, data\[1\] == 0xAC"
)

# Extract one dispatcher's body: from the line matching $2 to the line before the
# NEXT `transport.on...` handler in the same file (or EOF).
body () {  # file  start-pattern
  awk -v pat="$2" '
    $0 ~ pat && !started { started=1; print; next }
    started && /transport\.on[A-Za-z]+ *=/ { exit }
    started { print }
  ' "$1"
}

declare -a NAMES=("Mac 1-1" "Mac group" "iOS 1-1" "iOS group")
BODIES=()
BODIES+=("$(body "$MAC" 'transport.onReceive = ')")
BODIES+=("$(body "$MAC" 'transport.onReceiveFrom = ')")
BODIES+=("$(body "$IOS" 'transport.onData = ')")
BODIES+=("$(body "$IOS" 'transport.onDataFrom = ')")

fail=0
printf '%-22s' "subtype \\ dispatcher"
for n in "${NAMES[@]}"; do printf '%-11s' "$n"; done; printf '\n'
for entry in "${CORE[@]}"; do
  label="${entry%%|*}"; pat="${entry#*|}"
  printf '%-22s' "$label"
  for i in 0 1 2 3; do
    if grep -qE "$pat" <<<"${BODIES[$i]}"; then printf '%-11s' "ok"
    else printf '%-11s' "MISSING"; fail=1; fi
  done
  printf '\n'
done

if [ "$fail" -ne 0 ]; then
  echo "FAIL: a core call subtype is missing from a receive dispatcher (see MISSING above)."
  echo "Add the handler to that path — a subtype handled in one path but not its sibling"
  echo "silently drops that message (this is exactly how Mac group calls went audio-less)."
  exit 1
fi
echo "PASS: all core call subtypes handled in all four dispatchers."
