#!/usr/bin/env bash
# tests/test-gate-run.sh — gate orchestrator writes evidence + verdict
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-run-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-run"
rm -rf "$WORK"; mkdir -p "$WORK/repo" "$WORK/att"; _TEST_DIRS+=("$WORK")
echo "def greet(name): pass" > "$WORK/repo/greeter.py"

task='{"id":"t","goal":"g","acceptance_criteria":[
  {"id":"AC1","text":"exists","verify":{"cmd":"grep -q greet greeter.py"}},
  {"id":"AC2","text":"missing","verify":{"cmd":"grep -q nope greeter.py"}},
  {"id":"AC3","text":"pattern","verify":{"guidance":"matches"}}]}'

echo "=== gate FAIL (AC2) at attempt1 budget1 -> RETRY, evidence written ==="
v="$(_ccs_dispatch_gate_run "$WORK/repo" "$task" "$WORK/att" 1 1)"
assert_eq "returns RETRY" "RETRY" "$v"
assert_eq "AC1 evidence PASS" "PASS" "$(jq -r '.verdict' "$WORK/att/gate/AC1.json")"
assert_eq "AC2 evidence FAIL" "FAIL" "$(jq -r '.verdict' "$WORK/att/gate/AC2.json")"
assert_eq "AC3 evidence SKIPPED" "SKIPPED_FOR_LLM" "$(jq -r '.verdict' "$WORK/att/gate/AC3.json")"
assert_eq "verdict.json RETRY" "RETRY" "$(jq -r '.verdict' "$WORK/att/gate/verdict.json")"
assert_contains "verdict has timestamp" "$(jq -r '.timestamp' "$WORK/att/gate/verdict.json")" "T"

echo "=== all cmd PASS -> PASS ==="
task2='{"id":"t","goal":"g","acceptance_criteria":[
  {"id":"AC1","text":"exists","verify":{"cmd":"grep -q greet greeter.py"}}]}'
rm -rf "$WORK/att2"; mkdir -p "$WORK/att2"
v2="$(_ccs_dispatch_gate_run "$WORK/repo" "$task2" "$WORK/att2" 1 1)"
assert_eq "returns PASS" "PASS" "$v2"

test_summary
