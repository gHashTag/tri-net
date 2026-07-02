#!/usr/bin/env bash
# Quality gate for autonomous iterations: fmt + clippy(-D warnings) + tests.
# The loop/cron MUST pass this before committing or opening a PR.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "[verify] cargo fmt --check";   cargo fmt --all --check
echo "[verify] cargo clippy -D";     cargo clippy --all-targets -- -D warnings
echo "[verify] cargo test";          cargo test
echo "[verify] OK — safe to commit / open PR"
