#!/usr/bin/env python3
"""Create the TRI-NET drone-mesh issue set in gHashTag/trinity-fpga. Run once (not idempotent)."""
import os, subprocess, sys
REPO = "gHashTag/trinity-fpga"
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bodies")

# (slug, title, [labels]) in topological (dependency-safe) order
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

def gh(args, inp=None):
    r = subprocess.run(["gh"]+args, input=inp, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"gh {' '.join(args[:3])}... failed: {r.stderr.strip()}")
    return r.stdout.strip()

# ensure label exists
labels = gh(["label","list","-R",REPO,"--limit","200"])
if "drone-mesh" not in labels:
    gh(["label","create","drone-mesh","-R",REPO,"--color","1FA8A0",
        "--description","TRI-NET drone-mesh track — separate from fpga-matrix/GoldenFloat"])
    print("created label drone-mesh")

num = {}   # slug -> issue number
for slug, title, labs in ISSUES:
    body = open(os.path.join(DIR, slug+".md")).read()
    for s, n in num.items():                       # link deps -> #N (backticked first)
        body = body.replace(f"`{s}`", f"#{n}").replace(s, f"#{n}")
    args = ["issue","create","-R",REPO,"-t",title,"-F","-"]
    for l in labs: args += ["-l", l]
    url = gh(args, inp=body)
    num[slug] = url.rsplit("/",1)[-1]
    print(f"  #{num[slug]:<5} {title}")

# append filed-children checklist to the EPIC and update it
epic = num["epic-drone-mesh"]
extra = "\n\n---\n### Filed child issues\n" + "".join(
    f"- [ ] #{num[s]}\n" for s,_,_ in ISSUES if s != "epic-drone-mesh")
body = open(os.path.join(DIR,"epic-drone-mesh.md")).read() + extra
gh(["issue","edit",epic,"-R",REPO,"-F","-"], inp=body)
print(f"\nDone. EPIC = #{epic}  ->  https://github.com/{REPO}/issues/{epic}")
