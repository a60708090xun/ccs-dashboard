#!/usr/bin/env bash
# tests/test-gate-verdict.sh — gate verdict pure function (scope C)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-verdict-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

gv() { _ccs_dispatch_gate_verdict "$@"; }
allpass='[{"ac_id":"AC1","track":"cmd","verdict":"PASS"},{"ac_id":"AC2","track":"guidance","verdict":"SKIPPED_FOR_LLM"}]'
onefail='[{"ac_id":"AC1","track":"cmd","verdict":"PASS"},{"ac_id":"AC2","track":"cmd","verdict":"FAIL"}]'
oneerr='[{"ac_id":"AC1","track":"cmd","verdict":"ERROR"}]'
onehard='[{"ac_id":"AC1","track":"cmd","verdict":"HARD_STOP"}]'

echo "=== all cmd PASS (guidance ignored) -> PASS ==="
assert_eq "PASS" "PASS" "$(gv "$allpass" 1 1 | jq -r '.verdict')"

echo "=== FAIL within budget -> RETRY ==="
assert_eq "attempt1 budget1 -> RETRY" "RETRY" "$(gv "$onefail" 1 1 | jq -r '.verdict')"
assert_eq "failed_acs listed" "AC2" "$(gv "$onefail" 1 1 | jq -r '.failed_acs[0]')"
assert_eq "budget remaining" "0" "$(gv "$onefail" 1 1 | jq -r '.loop_budget_remaining')"

echo "=== FAIL budget exhausted -> ESCALATE ==="
assert_eq "attempt2 budget1 -> ESCALATE" "ESCALATE" "$(gv "$onefail" 2 1 | jq -r '.verdict')"

echo "=== ERROR -> ESCALATE regardless of budget ==="
assert_eq "ERROR -> ESCALATE" "ESCALATE" "$(gv "$oneerr" 1 1 | jq -r '.verdict')"

echo "=== HARD_STOP dominates ==="
assert_eq "HARD_STOP" "HARD_STOP" "$(gv "$onehard" 1 5 | jq -r '.verdict')"

echo "=== next_executor is same-executor (no tier ladder) ==="
assert_eq "reason" "same_executor_no_tier_ladder" "$(gv "$onefail" 1 1 | jq -r '.next_executor.reason')"

test_summary
