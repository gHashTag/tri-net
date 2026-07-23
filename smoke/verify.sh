#!/usr/bin/env bash
# verify.sh — one reproducible gate for the whole phone/ verification suite.
#
# Forty waves of correctness work lived in ephemeral scratchpad harnesses: a fresh
# checkout could not re-prove a single codec or crypto claim. The doctrine is
# "PROVEN requires reproduction" — so the harnesses now live in the repo and this
# runner replays every one against the REAL production source (never a copy, so it
# cannot drift), reporting a single PASS/FAIL.
#
# Each harness carries top-level code, which Swift only accepts from a file named
# main.swift in a multi-file build; we stage each as main.swift beside its source.
# The crypto harnesses touch the Keychain / UserDefaults and clean up after
# themselves (wipe at start and end) — they are safe to run on a dev Mac.
#
# What this canNOT cover, and why it stays separate:
#   * two_endpoint_rig.sh / two_endpoint_security.sh need TWO running apps and a
#     camera; they measure cross-process delivery and over-the-wire MITM, which a
#     compile-and-run harness cannot. Run those by hand (they self-report ALL PASS).
#
# Usage:  smoke/verify.sh
set -u
cd "$(dirname "$0")/.." || exit 2
SRC=phone/desktop/TriNetVideo
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The keychain harness must use an ISOLATED account. Once the real (signed) app has been launched
# it stores its device identity under the default account "device-ed25519"; a fresh UNSIGNED
# harness binary that then touches that signed item blocks on a GUI SecurityAgent authorization
# prompt that never arrives headless, and hangs (wave #46's app launch poisoned the shared keychain
# exactly this way -- the #41 watchdog caught it as a timeout). A harness-only account is owned by
# the harness binary itself, so no prompt. crypto_ room/replay/identity use explicit ephemeral
# identities and never read the keychain, so only crypto_keychain is affected; the app's real
# identity item is left untouched.
export TRINET_KC_ACCOUNT="verify"

# label : source-under-test : harness
SUITE=(
  "AudioRED         : $SRC/AudioRED.swift  : smoke/harness/audio_red.swift"
  "VideoFEC         : $SRC/VideoFEC.swift  : smoke/harness/video_fec.swift"
  "MeshCrypto room  : $SRC/MeshCrypto.swift: smoke/harness/crypto_room.swift"
  "MeshCrypto replay: $SRC/MeshCrypto.swift: smoke/harness/crypto_replay.swift"
  "MeshCrypto identity: $SRC/MeshCrypto.swift: smoke/harness/crypto_identity.swift"
  "MeshCrypto keychain: $SRC/MeshCrypto.swift: smoke/harness/crypto_keychain.swift"
  "Stun RFC5769     : $SRC/StunClient.swift: smoke/harness/stun_vectors.swift"
  "HolePunch        : $SRC/HolePunch.swift : smoke/harness/holepunch.swift"
  "IceSession       : $SRC/HolePunch.swift $SRC/IceSession.swift: smoke/harness/ice_session.swift"
  "CandidateOffer   : $SRC/MeshCrypto.swift $SRC/HolePunch.swift $SRC/IceSession.swift $SRC/CandidateOffer.swift: smoke/harness/candidate_offer.swift"
  "Rendezvous       : $SRC/MeshCrypto.swift $SRC/HolePunch.swift $SRC/IceSession.swift $SRC/CandidateOffer.swift $SRC/Rendezvous.swift: smoke/harness/rendezvous.swift"
)

pass=0; fail=0
# Kill a runaway harness after this many seconds. A crypto harness that reads the Keychain
# from a freshly-built unsigned binary blocks on a GUI SecurityAgent prompt that never
# arrives headless — it once wedged the whole gate for 8 minutes with no output. macOS has
# no `timeout(1)`, so we background the binary and reap it. All harnesses finish in <5s.
HARNESS_TIMEOUT=60
run_harness() {
  local label="$1" src="$2" harness="$3"
  # top-level code must be in a file literally named main.swift
  cp "$harness" "$TMP/main.swift"
  # $src may name more than one source file (space-separated); leave it unquoted so each is
  # a separate swiftc argument. TriNetVideo paths contain no spaces, so word-splitting is safe.
  if ! swiftc $src "$TMP/main.swift" -o "$TMP/bin" 2>"$TMP/err"; then
    echo "  FAIL  $label  (compile error)"; sed 's/^/        /' "$TMP/err" | head -8; fail=$((fail+1)); return
  fi
  "$TMP/bin" >"$TMP/out" 2>&1 &
  local bpid=$! rc=""
  for _ in $(seq "$HARNESS_TIMEOUT"); do
    kill -0 "$bpid" 2>/dev/null || { wait "$bpid"; rc=$?; break; }
    sleep 1
  done
  if [ -z "$rc" ]; then
    kill -9 "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null
    echo "  FAIL  $label  (TIMEOUT ${HARNESS_TIMEOUT}s — harness hung, likely a blocking Keychain prompt)"; fail=$((fail+1)); return
  fi
  if [ "$rc" = 0 ]; then
    echo "  PASS  $label  ($(grep -c '^PASS' "$TMP/out") checks)"; pass=$((pass+1))
  else
    echo "  FAIL  $label"; grep -E '^FAIL|FAILURE' "$TMP/out" | sed 's/^/        /'; fail=$((fail+1))
  fi
}

echo "== swiftc harnesses (compiled against real $SRC/*.swift) =="
for row in "${SUITE[@]}"; do
  IFS=':' read -r label src harness <<<"$row"
  run_harness "$(echo "$label" | xargs)" "$(echo "$src" | xargs)" "$(echo "$harness" | xargs)"
done

echo "== static guards =="
if bash smoke/dispatcher_parity.sh >"$TMP/dp" 2>&1; then
  echo "  PASS  dispatcher parity (4 receive paths agree on core subtypes)"; pass=$((pass+1))
else
  echo "  FAIL  dispatcher parity"; sed 's/^/        /' "$TMP/dp" | head; fail=$((fail+1))
fi

echo
echo "verify: $pass passed, $fail failed"
echo "(live rigs run separately: smoke/two_endpoint_rig.sh, smoke/two_endpoint_security.sh)"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILURE(S)"
exit "$fail"
