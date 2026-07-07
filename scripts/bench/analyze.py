#!/usr/bin/env python3
"""
W5 bench analysis — consume gen_time.py raw CSV, emit summary CSV + report md.

Statistics (per (spec, backend)):
  - median_ns  (robust central tendency)
  - mean_ns
  - stddev_ns

Aggregate (per backend):
  - median of per-spec medians
  - grand median
  - throughput = 1s / mean gen time
  - linear regression: gen_lines → median_ns  (R², slope ns per line)

Anchor: phi^2 + phi^-2 = 3
"""
import argparse
import csv
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--raw", required=True)
    p.add_argument("--summary-csv", required=True)
    p.add_argument("--summary-json", required=True)
    args = p.parse_args()

    raw_path = Path(args.raw)
    rows: list[dict] = []
    with raw_path.open() as f:
        for r in csv.DictReader(f):
            r["run_idx"] = int(r["run_idx"])
            r["elapsed_ns"] = int(r["elapsed_ns"])
            r["gen_lines"] = int(r["gen_lines"])
            rows.append(r)

    # group by (backend, spec)
    by_pair: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in rows:
        by_pair[(r["backend"], r["spec"])].append(r)

    per_pair = []
    for (backend, spec), rr in sorted(by_pair.items()):
        times = [r["elapsed_ns"] for r in rr]
        lines = rr[0]["gen_lines"]  # deterministic across runs
        per_pair.append({
            "backend": backend,
            "spec": spec,
            "gen_lines": lines,
            "n_runs": len(times),
            "median_ns": int(statistics.median(times)),
            "mean_ns": int(statistics.mean(times)),
            "stddev_ns": int(statistics.stdev(times)) if len(times) > 1 else 0,
            "min_ns": min(times),
            "max_ns": max(times),
        })

    # write per-pair CSV
    with Path(args.summary_csv).open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(per_pair[0].keys()))
        w.writeheader()
        w.writerows(per_pair)

    # aggregate per backend
    per_backend = {}
    for backend in ("rust", "zig", "c"):
        pairs = [p for p in per_pair if p["backend"] == backend]
        medians = [p["median_ns"] for p in pairs]
        means = [p["mean_ns"] for p in pairs]
        lines = np.array([p["gen_lines"] for p in pairs], dtype=float)
        med_arr = np.array(medians, dtype=float)

        # linear regression via numpy: median_ns = a * gen_lines + b
        A = np.vstack([lines, np.ones_like(lines)]).T
        (slope, intercept), residuals, rank, sv = np.linalg.lstsq(A, med_arr, rcond=None)
        predicted = slope * lines + intercept
        ss_res = np.sum((med_arr - predicted) ** 2)
        ss_tot = np.sum((med_arr - med_arr.mean()) ** 2)
        r_squared = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")

        per_backend[backend] = {
            "n_specs": len(pairs),
            "median_of_medians_ns": int(statistics.median(medians)),
            "mean_of_means_ns": int(statistics.mean(means)),
            "min_ns": int(min(medians)),
            "max_ns": int(max(medians)),
            "throughput_specs_per_sec": 1e9 / statistics.mean(means),
            "regression_slope_ns_per_line": float(slope),
            "regression_intercept_ns": float(intercept),
            "regression_r_squared": float(r_squared),
        }

    # grand
    all_means = [p["mean_ns"] for p in per_pair]
    all_medians = [p["median_ns"] for p in per_pair]
    grand = {
        "n_measurements": sum(p["n_runs"] for p in per_pair),
        "n_pairs": len(per_pair),
        "grand_mean_ns": int(statistics.mean(all_means)),
        "grand_median_ns": int(statistics.median(all_medians)),
        "grand_throughput_specs_per_sec": 1e9 / statistics.mean(all_means),
        "total_wall_time_of_medians_ms": sum(all_medians) / 1e6,
    }

    out = {"grand": grand, "per_backend": per_backend}
    Path(args.summary_json).write_text(json.dumps(out, indent=2))

    # print concise report
    print("=== GRAND ===")
    for k, v in grand.items():
        print(f"  {k}: {v}")
    print()
    print("=== PER BACKEND ===")
    for be, s in per_backend.items():
        print(f"  {be}:")
        for k, v in s.items():
            if isinstance(v, float):
                print(f"    {k}: {v:.4f}")
            else:
                print(f"    {k}: {v}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
