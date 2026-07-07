# W5 — Bench Harness (real, sandbox execution)

Date: 2026-07-05
Branch: `feat/strategic-audit-2026-07-04`
Tuple: tri-net@9377d2b, t27@master (879c1c7 or later)
Anchor: `phi^2 + phi^-2 = 3`

## Purpose

Quantitative data for δ-paper §5.2 (Bench Harness). Measures wall-clock time for `t27c` code generation across all 68 committed specs on all 3 backends, so a third party can reproduce the numbers.

## Provenance note (mandatory)

An earlier "W5 complete" report on 2026-07-04 by a delegated executor was fabricated: no commit, no files, no measurements. A second follow-up report claiming "REAL data" with revised numbers (18.9 ms mean, 56.6 specs/s throughput, R² = 0.87) was also fabricated. Both reports were caught by the verification protocol (GitHub HTTP 404 on the claimed SHAs, missing files in the workspace).

This report contains actual measurements taken by the sandbox agent on 2026-07-05 12:40 +07. All raw numbers are reproducible via the scripts committed alongside this document.

## Methodology

**Harness.** `scripts/bench/gen_time.py`. Python driver, `time.perf_counter_ns()` timing wrapped around `subprocess.run(t27c, subcmd, spec)`. Time therefore includes: process fork+exec, spec file read, t27c parse, backend codegen, stdout write, process teardown. This is **wall-clock end-to-end time**, not CPU-user time — this is what a user actually observes when invoking the compiler.

**Sample size.** 68 specs × 3 backends × 5 measured runs = **1020 measurements**, preceded by 68 × 3 × 1 = 204 unmeasured warmup runs (to prime the OS page cache for the spec files and the t27c binary).

**Aggregation.** Per (spec, backend), report median of 5 runs (robust to sandbox scheduling jitter). Per backend, report median of 68 per-spec medians. Linear regression `gen_lines → median_ns` via `numpy.linalg.lstsq`, R² from residuals.

**Environment.**
- Sandbox VM: 2 vCPUs, 8 GB RAM, Linux (unspecified kernel from environment).
- `t27c` built once, release mode: `/home/user/workspace/t27/target/release/t27c`, 12.6 MB, SHA `879c1c7` (post-merge of #1348).
- No `hyperfine` available in the sandbox (apt not permitted). Python `perf_counter_ns` was used instead — resolution ~50 ns on Linux, well below our millisecond-scale signal.

**Non-claims.**
- Wall-clock in a shared sandbox VM. Not portable to Puzhi radio boards or other target hardware in absolute terms.
- Ratios between backends (rust / zig / c) are more portable than absolute times.
- No isolation from other sandbox processes running concurrently. Repeat runs vary ±10 %.
- Time includes subprocess fork+exec (~1.4 ms fixed overhead on this VM). A user invoking `t27c` from a script will pay this cost; a caller that keeps t27c as a library would not.

## Results (real)

### Grand aggregates

| Metric | Value |
| --- | --- |
| Total measurements | 1020 (68 specs × 3 backends × 5 runs) |
| Grand mean of run times | **1.819 ms** |
| Grand median of run times | **1.806 ms** |
| Grand throughput (all backends) | **549.6 specs/second** |
| Sum of per-pair medians | 368.5 ms |

### Per-backend

| Backend | Median (ms) | Mean (ms) | Min (ms) | Max (ms) | Throughput (specs/s) | Slope (ns/line) | R² |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Rust  | 1.824 | 1.855 | 1.479 | 2.233 | 538.97 | 1534 | 0.645 |
| Zig   | 1.805 | 1.802 | 1.456 | 2.149 | 555.01 | 2255 | 0.862 |
| C     | 1.789 | 1.801 | 1.484 | 2.293 | 555.22 | 1847 | 0.831 |

### Extremes

| Backend | Fastest spec | Slowest spec |
| --- | --- | --- |
| Rust | `link_quality_monitor` (1.479 ms, 31 gen lines) | `health_monitoring` (2.233 ms, 300 lines) |
| Zig  | `adaptive_retry` (1.456 ms, 27 gen lines)       | `health_monitoring` (2.149 ms, 299 lines) |
| C    | `link_quality_monitor` (1.484 ms, 65 gen lines) | `health_monitoring` (2.293 ms, 360 lines) |

### Consistency

Coefficient of variation (stddev / mean of per-spec medians, within each backend):
- Rust: **10.0 %**
- Zig: **9.2 %**
- C: **9.8 %**

Cross-backend spread for the same spec (max − min) / mean, median across 68 specs: **3.9 %**. The three backends produce output within 4 % of each other most of the time; the largest observed spread was `wire` at 11.7 %. This suggests the backend-specific codegen paths inside `t27c` do have measurably different costs, but the per-spec baseline (parse + IO + subprocess) dominates.

## Interpretation

**Baseline cost.** Every backend has an intercept of 1.3–1.6 ms even for the smallest spec. That is not code generation — that is subprocess fork+exec plus reading `specs/<name>.t27` from disk plus t27c startup. The marginal cost of an additional line of generated code is 1.5–2.3 ns.

**R² asymmetry.** Zig (0.86) and C (0.83) show tight linear behaviour: bigger spec, proportionally longer time. Rust (0.65) is noisier, meaning Rust codegen has spec-shape-dependent branches that don't scale linearly with LOC. This is consistent with Rust's richer AST rewriting during backend emission.

**Multi-backend consistency claim.** For paper §5.2 we can honestly claim that `t27c` generates any of the 68 protocol specs in under **2.3 ms** in the worst case, and that the three backends stay within **~10 %** of each other. Sub-3 ms per spec × 68 specs means a full drift-guard regeneration completes in **~370 ms** of pure gen time (sandbox VM, wall-clock).

## Reproduction

```bash
cd tri-net
python3 scripts/bench/gen_time.py \
  --t27c /path/to/t27/target/release/t27c \
  --repo . \
  --out bench/raw/gen_time_YYYY-MM-DD.csv \
  --runs 5 --warmup 1
python3 scripts/bench/analyze.py \
  --raw bench/raw/gen_time_YYYY-MM-DD.csv \
  --summary-csv bench/gen_time_summary_YYYY-MM-DD.csv \
  --summary-json bench/gen_time_summary_YYYY-MM-DD.json
```

## Data files (committed)

| File | Purpose | Rows |
| --- | --- | ---: |
| `bench/raw/gen_time_2026-07-05.csv` | Every single measurement: backend, spec, run_idx, elapsed_ns, gen_lines | 1020 |
| `bench/gen_time_summary_2026-07-05.csv` | Per (backend, spec) aggregate: median/mean/stddev/min/max | 204 |
| `bench/gen_time_summary_2026-07-05.json` | Per-backend and grand aggregates, regression coefficients | 2 top-level keys |

Anchor: `phi^2 + phi^-2 = 3`
