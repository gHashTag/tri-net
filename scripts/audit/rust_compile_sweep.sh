#!/usr/bin/env bash
# W6.2 codegen audit — Rust per-file compile sweep
# Methodology: rustc --emit=metadata (equivalent to cargo check, skips codegen),
# per-file crate-root (gen/rust/*.rs are self-contained, no cross-file deps).
# Emits: report (per-file OK/FAIL + error counts), all_errors dump, E-code histogram.
#
# Note on scope: gen/rust/*.rs contain NO #[test] functions. This sweep therefore
# measures LIBRARY compilability only. Contrast with C and Zig sweeps, which
# include test-template code emitted by t27c (methodology asymmetry documented
# in docs/W6_CODEGEN_AUDIT_*.md).
#
# phi^2 + phi^-2 = 3

set -u

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1

if ! command -v rustc >/dev/null 2>&1; then
  echo "ERROR: rustc not in PATH" >&2
  exit 2
fi

tmp="$(mktemp -d /tmp/w6rustsweep.XXXXXX)"
ok=0
fail=0
: > "$tmp/all_errors.txt"
: > "$tmp/report.txt"

echo "# Rust compile sweep — $(date -u +%Y-%m-%dT%H:%M:%SZ)"                >> "$tmp/report.txt"
echo "# rustc: $(rustc --version)"                                          >> "$tmp/report.txt"
echo "# gen tree commit: $(git rev-parse HEAD)"                             >> "$tmp/report.txt"
echo "# gen/rust file count: $(ls gen/rust/*.rs | wc -l)"                   >> "$tmp/report.txt"
echo                                                                        >> "$tmp/report.txt"

for f in gen/rust/*.rs; do
  name="$(basename "$f" .rs)"
  out="$(rustc --edition 2021 --emit=metadata --crate-type lib \
        -o "$tmp/m.rmeta" "$f" 2>&1)"
  rc=$?
  if [ $rc -eq 0 ]; then
    ok=$((ok+1))
    printf 'OK   %s\n' "$name" >> "$tmp/report.txt"
  else
    fail=$((fail+1))
    printf '===FILE:%s===\n%s\n' "$name" "$out" >> "$tmp/all_errors.txt"
    nerr="$(printf '%s\n' "$out" | grep -Ec '^(error|error\[E)')"
    veclines="$(printf '%s\n' "$out" | grep -Ec 'Vec<')"
    printf 'FAIL %-28s errors=%-3s vec_lines=%s\n' \
        "$name" "$nerr" "$veclines" >> "$tmp/report.txt"
  fi
done

{
  printf '\n=== totals: OK=%s FAIL=%s / %s ===\n' "$ok" "$fail" "$((ok+fail))"
  printf '\n=== E-code histogram ===\n'
  grep -oE 'error\[E[0-9]+\]' "$tmp/all_errors.txt" | sort | uniq -c | sort -rn
  printf '\n=== bare error messages (top 10) ===\n'
  grep '^error:' "$tmp/all_errors.txt" | grep -v 'aborting due to' \
    | sort | uniq -c | sort -rn | head -10
} >> "$tmp/report.txt"

echo "REPORT=$tmp/report.txt"
echo "ERRORS=$tmp/all_errors.txt"
cat "$tmp/report.txt"
