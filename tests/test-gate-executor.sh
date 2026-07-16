#!/usr/bin/env bash
# tests/test-gate-executor.sh — executor field whitelist validation
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-executor-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-executor"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

mk() {  # mk <file> <executor-line-or-empty>
  local f="$WORK/$1" ex="$2"
  { echo "id: t"; echo "goal: g";
    [ -n "$ex" ] && echo "$ex";
    echo "acceptance_criteria:";
    echo "  - id: AC1";
    echo "    text: t";
    echo "    verify: {cmd: \"true\"}"; } > "$f"
  echo "$f"
}

echo "=== executor: gemini loads OK ==="
js="$(_ccs_dispatch_gate_load_task "$(mk g.yaml 'executor: gemini')")"; rc=$?
assert_eq "gemini rc 0" "0" "$rc"
assert_eq "gemini parsed" "gemini" "$(echo "$js" | jq -r '.executor')"

echo "=== executor: claude loads OK ==="
_ccs_dispatch_gate_load_task "$(mk c.yaml 'executor: claude')" >/dev/null 2>&1
assert_eq "claude rc 0" "0" "$?"

echo "=== omitted executor loads OK ==="
js2="$(_ccs_dispatch_gate_load_task "$(mk n.yaml '')")"; rc2=$?
assert_eq "omitted rc 0" "0" "$rc2"
assert_eq "omitted executor null" "null" "$(echo "$js2" | jq -r '.executor // "null"')"

echo "=== unknown executor -> rc 1 ==="
_ccs_dispatch_gate_load_task "$(mk bogus.yaml 'executor: codex')" >/dev/null 2>&1
assert_eq "unknown -> rc 1" "1" "$?"
_ccs_dispatch_gate_load_task "$(mk typo.yaml 'executor: gemeni')" >/dev/null 2>&1
assert_eq "typo -> rc 1" "1" "$?"

echo "=== executor: wingman needs plan (full coverage in test-gate-wingman.sh) ==="
_ccs_dispatch_gate_load_task "$(mk w.yaml 'executor: wingman')" >/dev/null 2>&1
assert_eq "wingman without plan -> rc 1" "1" "$?"

echo "=== non-string executor -> rc 1 ==="
_ccs_dispatch_gate_load_task "$(mk numeric.yaml 'executor: 123')" >/dev/null 2>&1
assert_eq "numeric -> rc 1" "1" "$?"
