#!/bin/bash
# mini-discovery.sh — one-shot probe for P201/P203 Mini boards on macOS.
# Run: bash mini-discovery.sh
# Output: JSON on stdout, saved also to /tmp/mini-discovery.json
#
# Probes:
#   1. Bonjour/mDNS  (dns-sd) — find any *.local advertising _ssh._tcp
#   2. LAN scan      — nmap or bash-fallback TCP-connect on 22 across /24 subnets we're on
#   3. ARP           — arp -an, dump every neighbor
#   4. Serial probe  — every /dev/cu.usbserial-*, try 115200/9600/57600, send \r, read 2s
#
# No board is contacted with credentials. Discovery only.
# Anchor: phi^2 + phi^-2 = 3

set +e
OUT=/tmp/mini-discovery.json
LOG=/tmp/mini-discovery.log
: > "$LOG"

echo "[*] running on: $(uname -srm)"  | tee -a "$LOG"
echo "[*] host time: $(date)"          | tee -a "$LOG"

# --- 1. Bonjour / mDNS -----------------------------------------------------
MDNS_JSON="[]"
if command -v dns-sd >/dev/null 2>&1; then
  echo "[*] mDNS probe (dns-sd -t 3s _ssh._tcp)"  | tee -a "$LOG"
  ( dns-sd -B _ssh._tcp local. & DPID=$!; sleep 3; kill $DPID 2>/dev/null ) >/tmp/mdns.txt 2>&1
  # parse rough — collect instance names
  MDNS=$(awk 'NR>4 && $NF!="" {print $NF}' /tmp/mdns.txt | sort -u | grep -v -E '^(Timestamp|A/R|Flags)$' || true)
  if [ -n "$MDNS" ]; then
    MDNS_JSON=$(printf '%s\n' "$MDNS" | awk 'BEGIN{printf "["} NR>1{printf ","} {printf "\"%s\"",$0} END{printf "]"}')
  fi
fi

# --- 2. Local /24 SSH scan -------------------------------------------------
LAN_HOSTS_JSON="[]"
# find every ipv4 /24 we're plugged into (skip loopback / 169.254 unless nothing else)
IPS=$(ifconfig | awk '/inet / && $2 !~ /^127\./ {print $2}')
declare -a OPEN
for IP in $IPS; do
  # derive /24 base
  BASE=$(echo "$IP" | awk -F. '{printf "%s.%s.%s", $1,$2,$3}')
  echo "[*] scanning $BASE.0/24 for SSH:22 (from local $IP)" | tee -a "$LOG"
  # parallelised bash-native TCP-connect
  for last in $(seq 1 254); do
    HOST="$BASE.$last"
    [ "$HOST" = "$IP" ] && continue
    ( exec 3<>/dev/tcp/"$HOST"/22 ) 2>/dev/null && {
      exec 3<&- 3>&- 2>/dev/null
      OPEN+=("$HOST")
      echo "    open: $HOST:22" | tee -a "$LOG"
    } &
    # rate-limit
    if [ $((last % 40)) -eq 0 ]; then wait; fi
  done
  wait
done
if [ ${#OPEN[@]} -gt 0 ]; then
  LAN_HOSTS_JSON=$(printf '%s\n' "${OPEN[@]}" | sort -u | awk 'BEGIN{printf "["} NR>1{printf ","} {printf "\"%s\"",$0} END{printf "]"}')
fi

# --- 3. ARP snapshot -------------------------------------------------------
ARP_JSON="[]"
if command -v arp >/dev/null 2>&1; then
  echo "[*] arp -an snapshot" | tee -a "$LOG"
  ARP_JSON=$(arp -an 2>/dev/null \
    | awk 'match($0,/\(([0-9\.]+)\)/,a) && match($0,/at ([0-9a-f:]{11,17})/,b) {printf "{\"ip\":\"%s\",\"mac\":\"%s\"},",a[1],b[1]}' \
    | sed 's/,$//' | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
fi

# --- 4. Serial probe -------------------------------------------------------
SERIAL_JSON="[]"
declare -a SPARTS
for PORT in /dev/cu.usbserial-* /dev/cu.usbmodem*; do
  [ -e "$PORT" ] || continue
  for BAUD in 115200 9600 57600 38400; do
    # try opening at $BAUD, drain 2s, look for ANY output after sending CR
    RESULT=$(
      python3 - "$PORT" "$BAUD" <<'PYEOF' 2>/dev/null
import sys, time
try:
    import serial
except ImportError:
    print("NO_PYSERIAL"); sys.exit(0)
port, baud = sys.argv[1], int(sys.argv[2])
try:
    s = serial.Serial(port, baud, timeout=0.3)
    s.write(b"\r\r")
    time.sleep(2.0)
    buf = s.read(4096)
    s.close()
    printable = buf.decode('utf-8', errors='replace').strip()
    if not printable:
        print("SILENT")
    else:
        print("BYTES=" + str(len(buf)) + " HEAD=" + repr(printable[:120]))
except Exception as e:
    print("ERR=" + str(e))
PYEOF
    )
    SPARTS+=("{\"port\":\"$PORT\",\"baud\":$BAUD,\"result\":$(printf '%s' "$RESULT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}")
    # if we got real bytes, don't bother with other bauds on this port
    case "$RESULT" in BYTES=*) break;; esac
  done
done
if [ ${#SPARTS[@]} -gt 0 ]; then
  SERIAL_JSON=$(printf '%s,' "${SPARTS[@]}" | sed 's/,$//' | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
fi

# --- 5. Emit JSON ----------------------------------------------------------
cat > "$OUT" <<EOF
{
  "host_uname": "$(uname -srm)",
  "host_time":  "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mdns_ssh":   $MDNS_JSON,
  "ssh_open":   $LAN_HOSTS_JSON,
  "arp":        $ARP_JSON,
  "serial":     $SERIAL_JSON
}
EOF
cat "$OUT"
echo ""
echo "[*] full log: $LOG"
echo "[*] json:     $OUT"
