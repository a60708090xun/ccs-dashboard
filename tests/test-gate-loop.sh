#!/usr/bin/env bash
# tests/test-gate-loop.sh — run loop: dispatch -> gate -> single retry -> final
# Spawn seam _ccs_dispatch_run_worker is mocked to simulate worker edits.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-loop-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-loop"; rm -rf "$WORK"; mkdir -p "$WORK/repo"
_TEST_DIRS+=("$WORK")

task_yaml="$WORK/task.yaml"
cat > "$task_yaml" <<YAML
id: loop-x
goal: "create greeter.py with greet()"
scope:
  cwd: "$WORK/repo"
execution_policy:
  loop_budget: 1
acceptance_criteria:
  - id: AC1
    text: "greet exists"
    verify:
      cmd: "grep -q 'def greet' greeter.py"
YAML

# Mock spawn: attempt 1 writes a WRONG file (FAIL), attempt 2 writes the right
# one (PASS). Simulates a worker that fixes itself after feedback.
_ccs_dispatch_run_worker() {
  local cwd="$1" prompt="$2" run_dir="$3" attempt="$4"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"
  if [ "$attempt" -eq 1 ]; then
    echo "def hello(): pass" > "$cwd/greeter.py"
  else
    echo "def greet(name): pass" > "$cwd/greeter.py"
  fi
  echo "worker ran attempt $attempt" \
    > "$run_dir/attempt-$(printf '%02d' "$attempt")/executor-output.md"
  return 0
}

echo "=== FAIL then PASS after retry -> accepted, 2 attempts ==="
chain_dir="$(_ccs_dispatch_run "$task_yaml")"; rc=$?
hop="$chain_dir/hop-01-loop-x"
assert_eq "exit 0 accepted" "0" "$rc"
assert_eq "hop outcome accepted" "accepted" "$(jq -r '.outcome' "$hop/final.json")"
assert_eq "two attempts" "2" "$(jq -r '.attempts' "$hop/final.json")"
assert_eq "attempt1 gate RETRY" "RETRY" "$(jq -r '.verdict' "$hop/attempt-01/gate/verdict.json")"
assert_eq "attempt2 gate PASS" "PASS" "$(jq -r '.verdict' "$hop/attempt-02/gate/verdict.json")"
assert_contains "attempt2 prompt carries feedback" "$(cat "$hop/attempt-02/prompt.md")" "AC1 FAIL"
assert_eq "task frozen" "loop-x" "$(_ccs_dispatch_gate_load_task "$hop/task.yaml" | jq -r '.id')"

echo "=== persistent FAIL -> escalated, exit 10 ==="
_ccs_dispatch_run_worker() {
  local cwd="$1" prompt="$2" run_dir="$3" attempt="$4"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"
  echo "def nope(): pass" > "$cwd/greeter.py"
  echo x > "$run_dir/attempt-$(printf '%02d' "$attempt")/executor-output.md"
  return 0
}
rm -f "$WORK/repo/greeter.py"
chain_dir2="$(_ccs_dispatch_run "$task_yaml")"; rc2=$?
assert_eq "exit 10 escalated" "10" "$rc2"
assert_eq "hop outcome escalated" "escalated" \
  "$(jq -r '.outcome' "$chain_dir2/hop-01-loop-x/final.json")"

test_summary
