#!/usr/bin/env python3
"""
W5 bench harness — measure t27c gen-{rust,zig,c} wall-clock time.

Methodology:
  1. Read spec list from .github/workflows/spec-drift-guard.yml (source of truth).
  2. For each (spec, backend) pair: N warm runs (1 warmup + N measured).
  3. Time via time.perf_counter_ns() spanning subprocess.run() call.
  4. Emit raw CSV: backend, spec, run_idx, elapsed_ns, gen_lines.

Non-claims:
  - Wall-clock, not CPU time (measures subprocess spawn + I/O + generation).
  - Sandbox VM, not target hardware. Absolute numbers not portable to Puzhi
    boards. Relative ratios (rust vs zig vs c) are more portable.
  - No isolation from other sandbox processes. Repeat runs may vary ±10%.

Anchor: phi^2 + phi^-2 = 3
"""
import argparse
import csv
import os
import re
import subprocess
import sys
import time
from pathlib import Path


def load_specs(workflow_path: Path) -> list[str]:
    txt = workflow_path.read_text()
    m = re.search(r"for spec in (.+?); do", txt)
    if not m:
        sys.exit(f"could not find 'for spec in ...; do' in {workflow_path}")
    return m.group(1).split()


def count_lines(path: Path) -> int:
    with path.open("rb") as f:
        return sum(1 for _ in f)


BACKENDS = [
    # (backend_name, t27c_subcommand, extension)
    ("rust", "gen-rust", "rs"),
    ("zig", "gen", "zig"),
    ("c", "gen-c", "c"),
]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--t27c", required=True, help="path to t27c binary")
    p.add_argument("--repo", required=True, help="tri-net repo root")
    p.add_argument("--out", required=True, help="output CSV path")
    p.add_argument("--runs", type=int, default=5, help="measured runs per pair")
    p.add_argument("--warmup", type=int, default=1, help="unmeasured warm-up runs")
    args = p.parse_args()

    repo = Path(args.repo).resolve()
    t27c = Path(args.t27c).resolve()
    workflow = repo / ".github" / "workflows" / "spec-drift-guard.yml"

    if not t27c.is_file():
        sys.exit(f"t27c not found: {t27c}")
    specs = load_specs(workflow)
    print(f"loaded {len(specs)} specs from {workflow.name}", file=sys.stderr)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    rows: list[dict] = []
    total = len(specs) * len(BACKENDS) * args.runs
    done = 0

    for backend, subcmd, ext in BACKENDS:
        for spec in specs:
            spec_path = repo / "specs" / f"{spec}.t27"
            assert spec_path.is_file(), spec_path

            # warmup: unmeasured, discarded
            for _ in range(args.warmup):
                subprocess.run(
                    [str(t27c), subcmd, str(spec_path)],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )

            # measured runs
            for run_idx in range(args.runs):
                t0 = time.perf_counter_ns()
                r = subprocess.run(
                    [str(t27c), subcmd, str(spec_path)],
                    check=True, capture_output=True,
                )
                t1 = time.perf_counter_ns()
                gen_lines = r.stdout.count(b"\n")
                rows.append({
                    "backend": backend,
                    "spec": spec,
                    "run_idx": run_idx,
                    "elapsed_ns": t1 - t0,
                    "gen_lines": gen_lines,
                })
                done += 1
                if done % 100 == 0:
                    print(f"  {done}/{total} measurements", file=sys.stderr)

    with out_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["backend", "spec", "run_idx", "elapsed_ns", "gen_lines"])
        w.writeheader()
        w.writerows(rows)

    print(f"wrote {len(rows)} rows to {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
