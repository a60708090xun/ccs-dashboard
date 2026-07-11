#!/usr/bin/env bash
# tests/test-dispatch-plan-cli.sh — public command surface
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-plan-cli-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-plan-cli"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

SPEC="$WORK/spec.yaml"
cat > "$SPEC" <<'YAML'
defaults:
  scope: { cwd: "/abs/proj" }
  executor: gemini
hops:
  - id: alpha
    goal: g
    acceptance_criteria:
      - { id: AC1, text: t, verify: { cmd: "true" } }
YAML

echo "=== default out dir = <spec-dir>/chain; stdout is exactly the entry path ==="
out="$(ccs-dispatch-plan "$SPEC" 2>/dev/null)"; rc=$?
assert_eq "cli rc 0" "0" "$rc"
assert_eq "entry path default out" "$WORK/chain/hop-01-alpha.task.yaml" "$out"
assert_eq "entry file exists" "yes" "$([ -f "$out" ] && echo yes)"
assert_eq "stdout single line" "1" "$(printf '%s' "$out" | grep -c .)"

echo "=== --out override ==="
DEST="$WORK/custom"
out2="$(ccs-dispatch-plan "$SPEC" --out "$DEST" 2>/dev/null)"
assert_eq "entry path custom out" "$DEST/hop-01-alpha.task.yaml" "$out2"

echo "=== summary goes to stderr, not stdout ==="
se="$(ccs-dispatch-plan "$SPEC" --out "$WORK/o4" 2>&1 >/dev/null)"
assert_contains "stderr has summary" "$se" "generated"

echo "=== composes with dispatch-run consumer: entry is loadable ==="
_ccs_dispatch_gate_load_task "$out" >/dev/null 2>&1
assert_eq "entry loadable by gate" "0" "$?"

echo "=== help + missing arg ==="
ccs-dispatch-plan --help >/dev/null 2>&1; assert_eq "help rc 0" "0" "$?"
ccs-dispatch-plan >/dev/null 2>&1; assert_eq "missing arg rc non-zero" "1" "$?"

echo "=== --out with no value: clean error, must NOT hang ==="
# run in a subshell under timeout so a regression (infinite loop) cannot hang the suite
timeout 5 bash -c "source '$SCRIPT_DIR/ccs-dashboard.sh'; ccs-dispatch-plan '$SPEC' --out" >/dev/null 2>&1
assert_eq "--out no value rc 1 (not 124 hang)" "1" "$?"

echo "=== unknown arg: rc non-zero ==="
ccs-dispatch-plan "$SPEC" --bogus >/dev/null 2>&1; assert_eq "unknown arg rc 1" "1" "$?"

test_summary
