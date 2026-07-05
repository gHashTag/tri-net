#!/usr/bin/env bash
# W6.2 codegen audit — C per-file compile sweep
# Methodology: cc -c -std=c11 -Wall -Wextra (compile to object, no linking).
# cc compiles ALL functions in each translation unit, including t27c-emitted
# void test_*() functions. This means the C sweep captures BOTH library defects
# AND test-template defects (e.g., 2-arg assert, undeclared identifiers in tests).
# This is asymmetric with the Rust sweep (library-only, no #[test] fns in
# gen/rust); the asymmetry is disclosed in docs/W6_CODEGEN_AUDIT_*.md.
#
# phi^2 + phi^-2 = 3

set -u

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1

if ! command -v cc >/dev/null 2>&1; then
  echo "ERROR: cc not in PATH" >&2
  exit 2
fi

tmp="$(mktemp -d /tmp/w6csweep.XXXXXX)"
ok=0
fail=0
: > "$tmp/all_errors.txt"
: > "$tmp/report.txt"

echo "# C compile sweep — $(date -u +%Y-%m-%dT%H:%M:%SZ)"                   >> "$tmp/report.txt"
echo "# cc: $(cc --version | head -1)"                                      >> "$tmp/report.txt"
echo "# gen tree commit: $(git rev-parse HEAD)"                             >> "$tmp/report.txt"
echo "# gen/c file count: $(ls gen/c/*.c | wc -l)"                          >> "$tmp/report.txt"
echo                                                                        >> "$tmp/report.txt"

for f in gen/c/*.c; do
  name="$(basename "$f" .c)"
  out="$(cc -c -std=c11 -Wall -Wextra -Wno-unused \
        -o "$tmp/x.o" "$f" 2>&1)"
  rc=$?
  nerr="$(printf '%s\n' "$out" | grep -Ec 'error:')"
  nwarn="$(printf '%s\n' "$out" | grep -Ec 'warning:')"
  if [ $rc -eq 0 ]; then
    ok=$((ok+1))
    printf 'OK   %-28s warns=%s\n' "$name" "$nwarn" >> "$tmp/report.txt"
  else
    fail=$((fail+1))
    printf '===FILE:%s===\n%s\n' "$name" "$out" >> "$tmp/all_errors.txt"
    printf 'FAIL %-28s errors=%-3s warns=%s\n' \
        "$name" "$nerr" "$nwarn" >> "$tmp/report.txt"
  fi
done

{
  printf '\n=== totals: OK=%s FAIL=%s / %s ===\n' "$ok" "$fail" "$((ok+fail))"
  printf '\n=== error family histogram (top 15) ===\n'
  grep 'error:' "$tmp/all_errors.txt" \
    | awk -F'error: ' '{print $2}' \
    | sed -E "s/[[:space:]]*at[[:space:]].*//; s/[\`\xE2\x80\x98\xE2\x80\x99][^\xE2]+[\`\xE2\x80\x98\xE2\x80\x99]/'X'/g" \
    | sort | uniq -c | sort -rn | head -15
} >> "$tmp/report.txt"

echo "REPORT=$tmp/report.txt"
echo "ERRORS=$tmp/all_errors.txt"
cat "$tmp/report.txt"
