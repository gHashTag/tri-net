#!/usr/bin/env python3
"""
W6.1 harness — run every fuzz-generated spec through all 3 t27c backends,
capture exit code + a short stderr classification, and assert that the
three backends AGREE on accept/reject.

Anchor: phi^2 + phi^-2 = 3.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

BACKENDS = [
    ("rust", "gen-rust"),
    ("zig", "gen"),
    ("c", "gen-c"),
]

# error class regexes (checked in order; first match wins)
CLASS_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("lex-error", re.compile(r"unexpected char|invalid token|lex", re.IGNORECASE)),
    ("parse-error", re.compile(r"parse|expected|unexpected token|unmatched", re.IGNORECASE)),
    ("type-error", re.compile(r"type|arity|arg", re.IGNORECASE)),
    ("unknown-ident", re.compile(r"undefined|unknown|unresolved|not in scope", re.IGNORECASE)),
    ("io-error", re.compile(r"no such file|permission", re.IGNORECASE)),
]


def classify(stderr: str, exit_code: int) -> str:
    if exit_code == 0:
        return "ok"
    for label, rx in CLASS_RULES:
        if rx.search(stderr):
            return label
    return "other-error"


@dataclass
class RunResult:
    filename: str
    bucket: str
    damage: str
    backend: str  # 'rust' | 'zig' | 'c'
    exit: int
    err_class: str
    stderr_head: str  # first 120 chars for provenance


def run_one(t27c: Path, spec: Path, sub: str) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            [str(t27c), sub, str(spec)],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        return proc.returncode, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "TIMEOUT"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--t27c", type=Path, required=True)
    ap.add_argument("--specs-dir", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    manifest_path = args.specs_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    args.out.mkdir(parents=True, exist_ok=True)
    raw_csv = args.out / "fuzz_raw.csv"
    agg_json = args.out / "fuzz_summary.json"

    rows: list[RunResult] = []
    for entry in manifest:
        spec = args.specs_dir / entry["filename"]
        for backend, sub in BACKENDS:
            code, err = run_one(args.t27c, spec, sub)
            rows.append(
                RunResult(
                    filename=entry["filename"],
                    bucket=entry["bucket"],
                    damage=entry["damage"],
                    backend=backend,
                    exit=code,
                    err_class=classify(err, code),
                    stderr_head=err.strip().replace("\n", " | ")[:120],
                )
            )

    with raw_csv.open("w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["filename", "bucket", "damage", "backend", "exit", "err_class", "stderr_head"])
        for r in rows:
            w.writerow([r.filename, r.bucket, r.damage, r.backend, r.exit, r.err_class, r.stderr_head])

    # aggregate: per file, do the three backends agree on accept/reject?
    per_file: dict[str, dict] = {}
    for r in rows:
        d = per_file.setdefault(
            r.filename, {"bucket": r.bucket, "damage": r.damage, "outcomes": {}}
        )
        d["outcomes"][r.backend] = {"exit": r.exit, "err_class": r.err_class}

    n_total = len(per_file)
    n_all_accept = 0
    n_all_reject = 0
    n_disagree = 0
    disagreements: list[dict] = []
    class_agree = 0
    class_disagree = 0

    for fname, d in per_file.items():
        exits = [d["outcomes"][b]["exit"] for b, _ in BACKENDS]
        classes = [d["outcomes"][b]["err_class"] for b, _ in BACKENDS]
        accepts = [e == 0 for e in exits]
        if all(accepts):
            n_all_accept += 1
        elif not any(accepts):
            n_all_reject += 1
            if len(set(classes)) == 1:
                class_agree += 1
            else:
                class_disagree += 1
        else:
            n_disagree += 1
            disagreements.append(
                {
                    "filename": fname,
                    "bucket": d["bucket"],
                    "damage": d["damage"],
                    "outcomes": d["outcomes"],
                }
            )

    # per-bucket breakdown
    bucket_stats: dict[str, dict] = {}
    for fname, d in per_file.items():
        b = d["bucket"]
        bs = bucket_stats.setdefault(
            b, {"total": 0, "all_accept": 0, "all_reject": 0, "disagree": 0}
        )
        bs["total"] += 1
        exits = [d["outcomes"][bk]["exit"] for bk, _ in BACKENDS]
        accepts = [e == 0 for e in exits]
        if all(accepts):
            bs["all_accept"] += 1
        elif not any(accepts):
            bs["all_reject"] += 1
        else:
            bs["disagree"] += 1

    summary = {
        "n_specs": n_total,
        "n_all_accept": n_all_accept,
        "n_all_reject": n_all_reject,
        "n_disagree": n_disagree,
        "agreement_pct": round(100.0 * (n_all_accept + n_all_reject) / n_total, 3) if n_total else 0.0,
        "reject_class_agree": class_agree,
        "reject_class_disagree": class_disagree,
        "per_bucket": bucket_stats,
        "disagreements": disagreements[:50],  # cap for readability
    }
    agg_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")

    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
