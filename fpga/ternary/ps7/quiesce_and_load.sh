#!/bin/sh
# Compatibility wrapper (#383 E3). The teardown this script performed now runs
# inside load_and_verify.sh itself, so one copied script is safe to run on a
# live board. Kept because the 2026-08-19 silicon log names this script.
#
# Usage: ./quiesce_and_load.sh /tmp/ps7_probe.swab.bin

set -e
BIN="${1:-/tmp/ps7_probe.swab.bin}"
exec sh "$(dirname "$0")/load_and_verify.sh" "$BIN"
