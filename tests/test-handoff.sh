#!/usr/bin/env bash
# tests/test-handoff.sh — ccs-handoff flag tests
# Run: bash tests/test-handoff.sh
#
# NOTE: source ccs-handoff.sh only (not
# ccs-dashboard.sh) because we only test
# flag parsing, which has no external deps.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-handoff.sh

echo "=== ccs-handoff flag handling ==="

# Case A: unknown flag rejected
ret_a=0
err_a=$(ccs-handoff --bogus 2>&1) \
  || ret_a=$?
assert_eq "A: unknown flag returns 1" \
  "1" "$ret_a"
assert_contains "A: unknown flag stderr" \
  "$err_a" "Unknown option"

# Case B: --help succeeds
ccs-handoff --help >/dev/null 2>&1
assert_eq "B: --help returns 0" "0" "$?"

# Case C: valid flag, no Unknown option
err_c=$(ccs-handoff --no-prompt \
  /nonexistent/path 2>&1 || true)
assert_not_contains "C: valid flag no Unknown" \
  "$err_c" "Unknown option"

# Case D: -n with value
err_d=$(ccs-handoff -n 3 \
  /nonexistent/path 2>&1 || true)
assert_not_contains "D: -n flag no Unknown" \
  "$err_d" "Unknown option"

test_summary
