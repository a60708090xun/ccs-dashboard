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

echo "=== executor: grok loads OK ==="
js_g="$(_ccs_dispatch_gate_load_task "$(mk grok.yaml 'executor: grok')")"; rc_g=$?
assert_eq "grok rc 0" "0" "$rc_g"
assert_eq "grok parsed" "grok" "$(echo "$js_g" | jq -r '.executor')"

echo "=== executor: opencode loads OK ==="
js_o="$(_ccs_dispatch_gate_load_task "$(mk opencode.yaml 'executor: opencode')")"; rc_o=$?
assert_eq "opencode rc 0" "0" "$rc_o"
assert_eq "opencode parsed" "opencode" "$(echo "$js_o" | jq -r '.executor')"

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

# Both the dedicated message and the jq whitelist reject these files, so rc
# alone would stay green with the dedicated check removed; assert the message.
echo "=== executor: wingman was removed -> dedicated error ==="
err_w="$(_ccs_dispatch_gate_load_task "$(mk w.yaml 'executor: wingman')" 2>&1 >/dev/null)"; rc_w=$?
assert_eq "wingman rejected rc 1" "1" "$rc_w"
assert_contains "wingman error points to opencode" "$err_w" "use executor: opencode"

echo "=== plan field was removed -> dedicated error ==="
err_p="$(_ccs_dispatch_gate_load_task "$(mk plan.yaml $'executor: claude\nplan: p.md')" 2>&1 >/dev/null)"; rc_p=$?
assert_eq "plan field rejected rc 1" "1" "$rc_p"
assert_contains "plan field error names removal" "$err_p" "field 'plan' was removed"

echo "=== empty plan field -> dedicated error ==="
err_e="$(_ccs_dispatch_gate_load_task "$(mk plan-empty.yaml $'executor: claude\nplan:')" 2>&1 >/dev/null)"; rc_e=$?
assert_eq "empty plan field rejected rc 1" "1" "$rc_e"
assert_contains "empty plan field error names removal" "$err_e" "field 'plan' was removed"

# An old wingman task carries both fields; the executor message, which names
# the replacement, must win over the plan message.
echo "=== old wingman task (executor + plan) -> executor message ==="
err_wp="$(_ccs_dispatch_gate_load_task "$(mk wp.yaml $'executor: wingman\nplan: p.md')" 2>&1 >/dev/null)"
assert_contains "old wingman task error points to opencode" "$err_wp" "use executor: opencode"
assert_not_contains "old wingman task: no plan message" "$err_wp" "field 'plan'"

echo "=== non-string executor -> rc 1 ==="
_ccs_dispatch_gate_load_task "$(mk numeric.yaml 'executor: 123')" >/dev/null 2>&1
assert_eq "numeric -> rc 1" "1" "$?"

test_summary
