#!/usr/bin/env bash
# Create the TRI-NET drone-mesh issue set in gHashTag/trinity-fpga.
# Requires: gh authenticated as an account with WRITE/triage on gHashTag/trinity-fpga
#   (e.g. `gh auth login` as gHashTag, or a PAT with Issues:write + repo access).
# Idempotency: NOT idempotent — running twice creates duplicate issues. Run once.
set -euo pipefail

REPO="gHashTag/trinity-fpga"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bodies"

# --- 0. label ---------------------------------------------------------------
if ! gh label list -R "$REPO" | grep -q '^drone-mesh'; then
  gh label create drone-mesh -R "$REPO" --color 1FA8A0 \
    --description "TRI-NET drone-mesh track — separate from fpga-matrix/GoldenFloat"
fi

declare -A NUM   # slug -> issue number

# create <slug> <title> <label,label,...>
create () {
  local slug="$1" title="$2" labels="$3"
  local body; body="$(cat "$DIR/$slug.md")"
  # substitute already-created dep slugs -> #N (backticked first, then bare)
  local s n
  for s in "${!NUM[@]}"; do
    n="${NUM[$s]}"
    body="${body//\`$s\`/#$n}"
    body="${body//$s/#$n}"
  done
  local args=(-R "$REPO" -t "$title" -F -)
  local IFS=','; for l in $labels; do args+=(-l "$l"); done; unset IFS
  local url; url="$(printf '%s' "$body" | gh issue create "${args[@]}")"
  local num="${url##*/}"
  NUM[$slug]="$num"
  printf '  #%-4s %s\n' "$num" "$title"
}

echo "Creating TRI-NET drone-mesh issues in $REPO ..."

# --- 1. EPIC + independent chores (no deps) --------------------------------
create epic-drone-mesh      "🎯 EPIC · feat(drone-mesh): TRI-NET drone-mesh bring-up (Phase 0–2)" "epic,drone-mesh"
create skill-fix-fpga-synth "fix(skill): correct fpga-synth SKILL.md hardcoded path + wrong board target" "bug,documentation,drone-mesh"
create docs-honest-status   "docs(fpga): fix IDCODE.md 100T/200T mislabel + reconcile over-claimed FLASH_HISTORY" "documentation,drone-mesh"
create p0-autoflash-portable "chore(fpga): de-hardcode AUTO_FLASH.sh foreign paths + parameterize cable" "P0,drone-mesh,bug"
create p0-ax7203-flash      "feat(fpga) P0: sanity-verify the connected AX7203 via existing OpenOCD/AL321 flow" "P0,drone-mesh"

# --- 2. deps on the above --------------------------------------------------
create tri-net-skill        "docs(skill): create on-disk tri-net skill (honest Phase-0 status)" "documentation,drone-mesh"
create p0-toolchain         "feat(fpga) P0: Zynq-7020 Mini toolchain bring-up + adopt proven AX7203 flow as baseline" "P0,drone-mesh,enhancement"
create p0-mini-boot         "feat(fpga) P0: boot ARM-Linux on Mini xc7z020 + confirm AD9361/GPS/PPS" "P0,drone-mesh"

# --- 3. P1 radio + mesh ----------------------------------------------------
create p1-ad9361-phy        "feat(fpga) P1: AD9361 5.8GHz TX/RX + OFDM PHY (single-carrier fallback)" "P1,drone-mesh,enhancement"
create p1-mesh-repo         "feat(mesh) P1: scaffold trios-mesh repo + M1 X25519/ChaCha20 on real ARM (Mini)" "P1,drone-mesh"
create p1-mesh-tun-etx      "feat(mesh) P1: trios-mesh M2 — TUN/netdev IP-over-radio with real ETX metric" "P1,drone-mesh"
create p1-iperf-2hop        "feat(mesh) P1: trios-mesh M3 — iperf3 over 2 hops through attenuators (P1 exit gate)" "P1,drone-mesh"

# --- 4. P2 DEMO GATE -------------------------------------------------------
create p2-shared-uplink     "feat(mesh) P2: trios-mesh M4 — share ONE uplink across 3-node triangle (DEMO GATE)" "P2,drone-mesh,enhancement"
create p2-self-heal         "feat(mesh) P2: trios-mesh M5 self-healing re-route + convergence metric (DEMO GATE)" "P2,drone-mesh"

# --- 5. append child checklist to the EPIC ---------------------------------
EPIC="${NUM[epic-drone-mesh]}"
{
  echo ""
  echo "---"
  echo "### Filed child issues"
  for slug in skill-fix-fpga-synth docs-honest-status p0-autoflash-portable p0-ax7203-flash \
              tri-net-skill p0-toolchain p0-mini-boot p1-ad9361-phy p1-mesh-repo \
              p1-mesh-tun-etx p1-iperf-2hop p2-shared-uplink p2-self-heal; do
    echo "- [ ] #${NUM[$slug]}"
  done
} >> "$DIR/epic-drone-mesh.md"
gh issue edit "$EPIC" -R "$REPO" -F "$DIR/epic-drone-mesh.md"

echo ""
echo "Done. EPIC = #$EPIC"
