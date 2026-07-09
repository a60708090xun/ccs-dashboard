#!/usr/bin/env bash
# tests/test-gate-ac.sh — single AC runner (cmd + guidance tracks)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-ac-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-ac"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")
echo "hello greet" > "$WORK/greeter.py"

echo "=== cmd PASS ==="
ac='{"id":"AC1","text":"t","verify":{"cmd":"grep -q greet greeter.py"}}'
out="$(_ccs_dispatch_gate_run_ac "$WORK" "$ac")"
assert_eq "verdict PASS" "PASS" "$(echo "$out" | jq -r '.verdict')"
assert_eq "exit 0" "0" "$(echo "$out" | jq -r '.exit_code')"
assert_eq "track cmd" "cmd" "$(echo "$out" | jq -r '.track')"
assert_eq "ac_id echoed" "AC1" "$(echo "$out" | jq -r '.ac_id')"

echo "=== cmd FAIL captures exit code ==="
ac='{"id":"AC2","text":"t","verify":{"cmd":"grep -q nope greeter.py"}}'
out="$(_ccs_dispatch_gate_run_ac "$WORK" "$ac")"
assert_eq "verdict FAIL" "FAIL" "$(echo "$out" | jq -r '.verdict')"
assert_eq "exit 1" "1" "$(echo "$out" | jq -r '.exit_code')"

echo "=== cmd runs in cwd, not caller dir ==="
ac='{"id":"AC3","text":"t","verify":{"cmd":"test -f greeter.py"}}'
out="$(cd / && _ccs_dispatch_gate_run_ac "$WORK" "$ac")"
assert_eq "cwd honored -> PASS" "PASS" "$(echo "$out" | jq -r '.verdict')"

echo "=== guidance track -> SKIPPED_FOR_LLM ==="
ac='{"id":"AC4","text":"t","verify":{"guidance":"looks right"}}'
out="$(_ccs_dispatch_gate_run_ac "$WORK" "$ac")"
assert_eq "verdict SKIPPED_FOR_LLM" "SKIPPED_FOR_LLM" "$(echo "$out" | jq -r '.verdict')"
assert_eq "track guidance" "guidance" "$(echo "$out" | jq -r '.track')"
assert_eq "cmd null" "null" "$(echo "$out" | jq -r '.cmd')"

test_summary
