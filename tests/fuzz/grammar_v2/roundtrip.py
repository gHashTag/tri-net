#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# tri-net/tests/fuzz/grammar_v2/roundtrip.py
#
# W7.3 E2 — Parse-invariance harness for grammar-directed fuzzer output.
#
# For each generated .t27 module (produced by `gen` binary from E1), runs
# a t27c parse-invariance sweep:
#
#   1. parse_ok: `t27c parse` returns 0 exit code (no parse error, no panic).
#   2. whitespace_invariance: introduce non-semantic whitespace mutations,
#      re-parse, and check that the AST-normalized form is identical to the
#      original AST-normalized form.
#
# The plan (W7_3_FUZZ_BASELINE_PLAN.md) originally called for a full round-
# trip via pretty-printer, but t27c doesn't expose a public pretty-printer
# in the current version. Parse-invariance is a strict subset of the intended
# round-trip check and still catches:
#   - parser non-determinism (identical input → identical AST twice)
#   - whitespace-sensitivity bugs (extra space or newline changing meaning)
#   - parser panics on well-formed input
#
# Full round-trip via pretty-printer is a TODO once t27c exposes one.
#
# Usage:
#   python3 roundtrip.py <fuzz_dir> [--t27c PATH] [--limit N]
#
# Exits 0 if all invariants hold across all inputs.
# phi^2 + phi^-2 = 3

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def normalize_ast(ast_text: str) -> str:
    """Normalize t27c's Debug-printed AST for structural comparison.

    Strategy:
      1. Strip `line: N,` fields — these are source-position metadata
         derived from layout, not structural AST content. Extra newlines
         in source shift them without changing meaning.
      2. Collapse all whitespace runs to a single space and strip.

    If a whitespace mutation changes the AST after this normalization,
    it is a real structural change, not a metadata artifact.
    """
    stripped = re.sub(r"\bline:\s*\d+,?", "", ast_text)
    return re.sub(r"\s+", " ", stripped).strip()


def run_parse(t27c: str, path: Path, timeout: float = 15.0):
    """Run t27c parse and return (returncode, stdout, stderr)."""
    try:
        proc = subprocess.run(
            [t27c, "parse", str(path)],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"


def whitespace_mutate(src: str, mode: str) -> str:
    """Introduce non-semantic whitespace mutations."""
    if mode == "extra_spaces":
        # Double every single-space run inside indentation.
        return re.sub(r"(?m)^( +)", lambda m: m.group(1) * 2, src)
    if mode == "extra_newlines":
        # Add a blank line after every closing brace.
        return re.sub(r"\}\n", "}\n\n", src)
    if mode == "trailing_ws":
        # Add trailing spaces to every non-empty line.
        return re.sub(r"(?m)([^\n ])$", r"\1   ", src)
    return src


MUTATIONS = ["extra_spaces", "extra_newlines", "trailing_ws"]


def analyze_one(t27c: str, spec_path: Path, tmp_dir: Path) -> dict:
    """Analyze one input spec across parse + whitespace invariance."""
    src = spec_path.read_text()

    # 1. Baseline parse.
    rc0, out0, err0 = run_parse(t27c, spec_path)
    if rc0 != 0:
        return {
            "file": spec_path.name,
            "parse_ok": False,
            "invariance_ok": False,
            "class": "parse_error",
            "stderr_head": err0.splitlines()[:3],
        }

    baseline_norm = normalize_ast(out0)

    # 2. Determinism: parse again, compare.
    rc1, out1, _ = run_parse(t27c, spec_path)
    if rc1 != 0 or normalize_ast(out1) != baseline_norm:
        return {
            "file": spec_path.name,
            "parse_ok": True,
            "invariance_ok": False,
            "class": "non_determinism",
        }

    # 3. Whitespace mutations.
    for mode in MUTATIONS:
        mutated = whitespace_mutate(src, mode)
        mut_path = tmp_dir / f"{spec_path.stem}__{mode}.t27"
        mut_path.write_text(mutated)
        rc_m, out_m, err_m = run_parse(t27c, mut_path)
        if rc_m != 0:
            return {
                "file": spec_path.name,
                "parse_ok": True,
                "invariance_ok": False,
                "class": f"mutation_broke_parse:{mode}",
                "stderr_head": err_m.splitlines()[:3],
            }
        if normalize_ast(out_m) != baseline_norm:
            return {
                "file": spec_path.name,
                "parse_ok": True,
                "invariance_ok": False,
                "class": f"mutation_changed_ast:{mode}",
            }

    return {
        "file": spec_path.name,
        "parse_ok": True,
        "invariance_ok": True,
        "class": "ok",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fuzz_dir", type=Path)
    ap.add_argument(
        "--t27c",
        default="/home/user/workspace/t27/target/release/t27c",
        help="Path to t27c binary",
    )
    ap.add_argument("--limit", type=int, default=0, help="Max files to check (0 = all)")
    ap.add_argument("--out", type=Path, default=None, help="Optional JSON report path")
    ap.add_argument(
        "--tmp",
        type=Path,
        default=Path("/tmp/w73_roundtrip_tmp"),
        help="Temp dir for mutated variants",
    )
    args = ap.parse_args()

    if not args.fuzz_dir.exists():
        print(f"ERROR: fuzz_dir {args.fuzz_dir} does not exist", file=sys.stderr)
        sys.exit(2)
    if not Path(args.t27c).exists():
        print(f"ERROR: t27c binary {args.t27c} not found", file=sys.stderr)
        sys.exit(2)

    args.tmp.mkdir(parents=True, exist_ok=True)

    files = sorted(args.fuzz_dir.glob("*.t27"))
    if args.limit > 0:
        files = files[: args.limit]

    print(f"W7.3 E2: analyzing {len(files)} files against t27c={args.t27c}")

    results = []
    counts = {"parse_error": 0, "non_determinism": 0, "ok": 0, "mutation_fail": 0}
    for i, path in enumerate(files):
        r = analyze_one(args.t27c, path, args.tmp)
        results.append(r)
        cls = r["class"]
        if cls == "ok":
            counts["ok"] += 1
        elif cls == "parse_error":
            counts["parse_error"] += 1
        elif cls == "non_determinism":
            counts["non_determinism"] += 1
        else:
            counts["mutation_fail"] += 1
        if (i + 1) % 50 == 0 or i + 1 == len(files):
            print(f"  {i+1}/{len(files)}  ok={counts['ok']}  parse_err={counts['parse_error']}  mut_fail={counts['mutation_fail']}  non_det={counts['non_determinism']}")

    summary = {
        "total": len(files),
        "counts": counts,
        "parse_ok_rate": (counts["ok"] + counts["mutation_fail"] + counts["non_determinism"]) / max(1, len(files)),
        "invariance_ok_rate": counts["ok"] / max(1, len(files)),
        "t27c": str(args.t27c),
    }
    print()
    print("=== Summary ===")
    print(json.dumps(summary, indent=2))

    if args.out:
        args.out.write_text(json.dumps({"summary": summary, "results": results}, indent=2))
        print(f"Full report: {args.out}")

    # Exit code reflects invariance success — 0 iff all inputs are ok.
    sys.exit(0 if counts["ok"] == len(files) else 1)


if __name__ == "__main__":
    main()
