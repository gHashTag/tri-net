#!/usr/bin/env python3
"""Recreate the drone-mesh issue set in gHashTag/tri-net, then close the originals in
gHashTag/trinity-fpga with a 'Moved to ...' pointer. Run once."""
import os, subprocess, sys, json, base64
NEW = "gHashTag/tri-net"
OLD = "gHashTag/trinity-fpga"
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bodies")

ISSUES = [
 ("epic-drone-mesh",      "🎯 EPIC · feat(drone-mesh): TRI-NET drone-mesh bring-up (Phase 0–2)", ["epic","drone-mesh"]),
 ("skill-fix-fpga-synth", "fix(skill): correct fpga-synth SKILL.md hardcoded path + wrong board target", ["bug","documentation","drone-mesh"]),
 ("docs-honest-status",   "docs(fpga): fix IDCODE.md 100T/200T mislabel + reconcile over-claimed FLASH_HISTORY", ["documentation","drone-mesh"]),
 ("p0-autoflash-portable","chore(fpga): de-hardcode AUTO_FLASH.sh foreign paths + parameterize cable", ["P0","drone-mesh","bug"]),
 ("p0-ax7203-flash",      "feat(fpga) P0: sanity-verify the connected AX7203 via existing OpenOCD/AL321 flow", ["P0","drone-mesh"]),
 ("tri-net-skill",        "docs(skill): create on-disk tri-net skill (honest Phase-0 status)", ["documentation","drone-mesh"]),
 ("p0-toolchain",         "feat(fpga) P0: Zynq-7020 Mini toolchain bring-up + adopt proven AX7203 flow as baseline", ["P0","drone-mesh","enhancement"]),
 ("p0-mini-boot",         "feat(fpga) P0: boot ARM-Linux on Mini xc7z020 + confirm AD9361/GPS/PPS", ["P0","drone-mesh"]),
 ("p1-ad9361-phy",        "feat(fpga) P1: AD9361 5.8GHz TX/RX + OFDM PHY (single-carrier fallback)", ["P1","drone-mesh","enhancement"]),
 ("p1-mesh-repo",         "feat(mesh) P1: scaffold trios-mesh repo + M1 X25519/ChaCha20 on real ARM (Mini)", ["P1","drone-mesh"]),
 ("p1-mesh-tun-etx",      "feat(mesh) P1: trios-mesh M2 — TUN/netdev IP-over-radio with real ETX metric", ["P1","drone-mesh"]),
 ("p1-iperf-2hop",        "feat(mesh) P1: trios-mesh M3 — iperf3 over 2 hops through attenuators (P1 exit gate)", ["P1","drone-mesh"]),
 ("p2-shared-uplink",     "feat(mesh) P2: trios-mesh M4 — share ONE uplink across 3-node triangle (DEMO GATE)", ["P2","drone-mesh","enhancement"]),
 ("p2-self-heal",         "feat(mesh) P2: trios-mesh M5 self-healing re-route + convergence metric (DEMO GATE)", ["P2","drone-mesh"]),
]

README = """# tri-net

**TRI-NET drone-mesh** — "Starlink without satellites": a self-organizing mesh/swarm of
relay drones + fixed nodes that share one internet uplink. Part of the Trinity Project.
Anchor: **phi^2 + phi^-2 = 3**.

> Naming: this is the **drone-mesh internet-delivery** track, distinct from the ternary-computing
> "TRI-NET" silicon-node work.

## Honest Phase-0 status (report v2.2)
Every unverified hardware claim carries a `-sim` marker.
- FPGA **never flashed** on a real Mini (Zynq-7020) node; no Zynq toolchain. `-sim`
- `trios-mesh` (ETX + X25519 + ChaCha20-Poly1305) passes unit tests **in simulation only**; no code yet. `-sim`
- Radio-PHY / 5.8 GHz OFDM / AD9361 / external PA+LNA = greenfield. `-sim`
- **AX7203 is real and proven**: openXC7 flow flashes it on silicon (OpenOCD + AL321, IDCODE `0x13636093`).

## Boards
| Board | Chip | Role |
|---|---|---|
| ALINX AX7203 | Artix-7 `xc7a200t` (IDCODE `0x13636093`) | bench compute + video-radio + 2xGbE mesh (proven) |
| P201/P203 Mini | Zynq-7020 `xc7z020` + AD9361 SDR + GPS/PPS | flying MVP radio node (never flashed; external PA+LNA @5.8 GHz needed) |

## Roadmap
- **P0** (wk1) — toolchain bring-up + first flash (Mini boot ARM-Linux + AD9361/GPS/PPS; AX7203 sanity).
- **P1** (wk2-3) — AD9361 5.8 GHz + OFDM PHY; `trios-mesh` M1 crypto-on-ARM -> M2 TUN/ETX -> M3 iperf3 over 2 hops (bench attenuators).
- **P2 = DEMO GATE** (wk5-6) — 3-node triangle, ONE shared uplink over the mesh, M4 + M5 self-healing (measured convergence). Deliverable: video + metrics + Apache-2.0 + Zenodo DOI.
- **P3** video-radio = drone C2 (MAVLink) on one radio · **P4** tethered drone (Flying-COW) · **P5** free swarm.

See the [`drone-mesh`](https://github.com/gHashTag/tri-net/issues?q=is%3Aissue+label%3Adrone-mesh) issues (EPIC + P0/P1/P2 children).

## Related repos
`gHashTag/trinity` · `gHashTag/trinity-fpga` (FPGA infra) · `gHashTag/openFPGALoader` · `gHashTag/trios-mesh` (to be created).
"""

def gh(args, inp=None, check=True):
    r = subprocess.run(["gh"]+args, input=inp, capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"gh {' '.join(args[:4])}... failed: {r.stderr.strip()}")
    return r.stdout.strip(), r.returncode

# 1) README (skip if present)
_, rc = gh(["api", f"repos/{NEW}/contents/README.md"], check=False)
if rc != 0:
    b64 = base64.b64encode(README.encode()).decode()
    gh(["api","-X","PUT",f"repos/{NEW}/contents/README.md",
        "-f","message=docs: initial README — TRI-NET drone-mesh", "-f", f"content={b64}"])
    print("added README.md")
else:
    print("README.md already exists, skipping")

# 2) map old issue numbers by title (robust)
out, _ = gh(["issue","list","-R",OLD,"--label","drone-mesh","--state","all","--limit","100",
             "--json","number,title"])
old_by_title = {i["title"]: i["number"] for i in json.loads(out)}

# 3) recreate in NEW with dep + epic-checklist relinking
num = {}
for slug, title, labs in ISSUES:
    body = open(os.path.join(DIR, slug+".md")).read()
    for s, n in num.items():
        body = body.replace(f"`{s}`", f"#{n}").replace(s, f"#{n}")
    args = ["issue","create","-R",NEW,"-t",title,"-F","-"]
    for l in labs: args += ["-l", l]
    url, _ = gh(args, inp=body)
    num[slug] = url.rsplit("/",1)[-1]
    print(f"  new #{num[slug]:<4} {title[:60]}")

epic = num["epic-drone-mesh"]
extra = "\n\n---\n### Filed child issues\n" + "".join(
    f"- [ ] #{num[s]}\n" for s,_,_ in ISSUES if s != "epic-drone-mesh")
body = open(os.path.join(DIR,"epic-drone-mesh.md")).read() + extra
gh(["issue","edit",epic,"-R",NEW,"-F","-"], inp=body)

# 4) close originals in OLD with pointer
print("\nClosing originals in", OLD)
mapping = []
for slug, title, _ in ISSUES:
    old = old_by_title.get(title)
    new = num[slug]
    if not old:
        print(f"  ! no original found for: {title[:50]}")
        continue
    gh(["issue","close",str(old),"-R",OLD,"--reason","not planned",
        "-c",f"Moved to {NEW}#{new} — this track now lives in the dedicated `tri-net` repo."])
    mapping.append({"slug":slug,"old":old,"new":int(new)})
    print(f"  closed {OLD}#{old} -> {NEW}#{new}")

json.dump(mapping, open(os.path.join(os.path.dirname(DIR),"move_map.json"),"w"), indent=1)
print(f"\nDone. New EPIC = {NEW}#{epic} -> https://github.com/{NEW}/issues/{epic}")
