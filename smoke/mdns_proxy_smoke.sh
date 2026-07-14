#!/usr/bin/env bash
# mdns_proxy_smoke.sh -- two-process overlay smoke for the RFC 8766 style
# Discovery Proxy. Starts one proxy server and drives it with a client over
# real TCP, exercising the generated qtype routing table (gen/rust/mdns_proxy.rs,
# from specs/mdns_proxy.t27):
#   - PTR (12) -> ROUTE_LOCAL   -> status 0, payload "LOCAL:<qname>"
#   - A   (1)  -> ROUTE_FORWARD -> status 0, payload "FORWARD"
#   - 9999     -> ROUTE_DROP    -> status 2 (refused), empty payload
#
# Runs the full triple N times (default 5) and requires identical results
# every pass (determinism gate). The binary is built standalone with rustc so
# it links only the generated proxy module, not the whole crate.
#
# phi^2 + phi^-2 = 3

set -euo pipefail

cd "$(dirname "$0")/.."

N="${1:-5}"
PORT="${MDNS_PROXY_PORT:-15353}"
ADDR="127.0.0.1:${PORT}"
BIN=target/spec-first/mdns_proxy

mkdir -p target/spec-first
if [[ ! -x "$BIN" || src/bin/mdns_proxy.rs -nt "$BIN" ]]; then
  echo "[smoke] building mdns_proxy (standalone rustc, generated module linked)"
  rustc -O --edition 2021 -A dead_code -A unused_parens -A unused-comparisons \
    src/bin/mdns_proxy.rs -o "$BIN"
fi

"$BIN" --serve "$ADDR" &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true' EXIT

# Wait for the listener to accept connections.
for _ in $(seq 1 50); do
  if "$BIN" --query "$ADDR" 12 _probe._tcp.local >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

expect() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" != "$want" ]]; then
    echo "[smoke] FAIL ($label): got [$got] want [$want]"
    exit 1
  fi
}

pass=0
for i in $(seq 1 "$N"); do
  ptr=$("$BIN" --query "$ADDR" 12 _admin._tcp.local)
  a=$("$BIN" --query "$ADDR" 1 host.local)
  drop=$("$BIN" --query "$ADDR" 9999 bad.local)

  expect "$ptr"  "status=0 payload=LOCAL:_admin._tcp.local" "PTR local pass $i"
  expect "$a"    "status=0 payload=FORWARD"                 "A forward pass $i"
  expect "$drop" "status=2 payload="                        "unknown drop pass $i"
  pass=$((pass + 1))
done

echo "[smoke] mdns_proxy: ${pass}/${N} passes, all routes correct (PTR=local, A=forward, unknown=refused)"
echo "[smoke] OK"
