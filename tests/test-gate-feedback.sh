#!/usr/bin/env bash
# tests/test-gate-feedback.sh — retry failure summary (§6)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-fb-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-fb"; rm -rf "$WORK"; mkdir -p "$WORK/gate"
_TEST_DIRS+=("$WORK")
echo '{"ac_id":"AC1","track":"cmd","verdict":"PASS","cmd":"true","exit_code":0}' > "$WORK/gate/AC1.json"
echo '{"ac_id":"AC2","track":"cmd","verdict":"FAIL","cmd":"grep -q x f","exit_code":1}' > "$WORK/gate/AC2.json"

echo "=== feedback lists only FAILed ACs with machine facts ==="
fb="$(_ccs_dispatch_gate_feedback "$WORK" 1)"
assert_contains "mentions attempt" "$fb" "attempt-1"
assert_contains "lists AC2" "$fb" "AC2"
assert_contains "shows the cmd" "$fb" "grep -q x f"
assert_contains "shows exit code" "$fb" "exit 1"
assert_not_contains "does not list passing AC1" "$fb" "AC1"

echo "=== no failures -> empty ==="
rm -f "$WORK/gate/AC2.json"
assert_eq "no fail -> empty" "" "$(_ccs_dispatch_gate_feedback "$WORK" 1)"

test_summary
