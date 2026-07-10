#!/usr/bin/env bash
# tests/test-gate-chain-task.sh — task.yaml `next:` validation
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-chain-task-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-chain-task"; rm -rf "$WORK"; mkdir -p "$WORK"
_TEST_DIRS+=("$WORK")

base='id: t1
goal: "g"
acceptance_criteria:
  - id: AC1
    text: "x"
    verify:
      cmd: "true"'

echo "=== valid next: loads ==="
printf '%s\nnext: t2.yaml\n' "$base" > "$WORK/ok.yaml"
_ccs_dispatch_gate_load_task "$WORK/ok.yaml" >/dev/null 2>&1
assert_eq "next present -> rc 0" "0" "$?"
assert_eq "next value parsed" "t2.yaml" \
  "$(_ccs_dispatch_gate_load_task "$WORK/ok.yaml" | jq -r '.next')"

echo "=== absent next: still valid ==="
printf '%s\n' "$base" > "$WORK/nonext.yaml"
_ccs_dispatch_gate_load_task "$WORK/nonext.yaml" >/dev/null 2>&1
assert_eq "no next -> rc 0" "0" "$?"

echo "=== empty next: rejected ==="
printf '%s\nnext: ""\n' "$base" > "$WORK/empty.yaml"
_ccs_dispatch_gate_load_task "$WORK/empty.yaml" >/dev/null 2>&1
assert_eq "empty next -> rc 1" "1" "$?"

test_summary
