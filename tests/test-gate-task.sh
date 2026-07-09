#!/usr/bin/env bash
# tests/test-gate-task.sh — task.yaml loader + validation
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-task-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-task"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

good="$WORK/task.yaml"
cat > "$good" <<'YAML'
id: task-x
goal: "do the thing"
acceptance_criteria:
  - id: AC1
    text: "greeter exists"
    verify:
      cmd: "grep -q foo bar"
  - id: AC2
    text: "matches project pattern"
    verify:
      guidance: "diff matches src/loader.py"
YAML

echo "=== loader emits JSON with fields ==="
js="$(_ccs_dispatch_gate_load_task "$good")"; rc=$?
assert_eq "load rc 0" "0" "$rc"
assert_eq "id parsed" "task-x" "$(echo "$js" | jq -r '.id')"
assert_eq "AC1 cmd parsed" "grep -q foo bar" \
  "$(echo "$js" | jq -r '.acceptance_criteria[0].verify.cmd')"
assert_eq "AC2 guidance parsed" "diff matches src/loader.py" \
  "$(echo "$js" | jq -r '.acceptance_criteria[1].verify.guidance')"

echo "=== validation failures rc 1 ==="
_ccs_dispatch_gate_load_task "$WORK/nope.yaml" >/dev/null 2>&1
assert_eq "missing file -> rc 1" "1" "$?"

cat > "$WORK/noac.yaml" <<'YAML'
id: t
goal: g
acceptance_criteria: []
YAML
_ccs_dispatch_gate_load_task "$WORK/noac.yaml" >/dev/null 2>&1
assert_eq "empty AC list -> rc 1" "1" "$?"

cat > "$WORK/bothtracks.yaml" <<'YAML'
id: t
goal: g
acceptance_criteria:
  - id: AC1
    text: t
    verify: {cmd: "true", guidance: "x"}
YAML
_ccs_dispatch_gate_load_task "$WORK/bothtracks.yaml" >/dev/null 2>&1
assert_eq "AC with both tracks -> rc 1" "1" "$?"

test_summary
