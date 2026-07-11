#!/usr/bin/env bash
# tests/test-dispatch-plan-expand.sh — deterministic chain-spec expansion
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-plan-expand-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-plan-expand"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

SPEC="$WORK/spec.yaml"
cat > "$SPEC" <<'YAML'
defaults:
  scope: { cwd: "/abs/proj" }
  executor: gemini
  execution_policy: { loop_budget: 1 }
hops:
  - id: hop1
    goal: "make thing"
    acceptance_criteria:
      - id: AC1
        text: "exists"
        verify: { cmd: "test -f thing" }
  - id: hop2
    goal: "extend thing"
    executor: claude
    acceptance_criteria:
      - id: AC1
        text: "extended"
        verify: { cmd: "grep -q more thing" }
YAML

DEST="$WORK/chain"
entry="$(_ccs_dispatch_plan_expand "$SPEC" "$DEST")"; rc=$?

echo "=== expansion succeeds, entry is hop-01 ==="
assert_eq "expand rc 0" "0" "$rc"
assert_eq "entry filename" "hop-01-hop1.task.yaml" "$entry"

echo "=== both hop files written ==="
assert_eq "hop1 exists" "yes" "$([ -f "$DEST/hop-01-hop1.task.yaml" ] && echo yes)"
assert_eq "hop2 exists" "yes" "$([ -f "$DEST/hop-02-hop2.task.yaml" ] && echo yes)"

# helper: read a JSON field from an emitted task.yaml via the same parser load_task uses
jread() { python3 -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1"; }

echo "=== defaults merged; per-hop override wins ==="
h1="$(jread "$DEST/hop-01-hop1.task.yaml")"
h2="$(jread "$DEST/hop-02-hop2.task.yaml")"
assert_eq "hop1 inherits gemini" "gemini" "$(echo "$h1" | jq -r '.executor')"
assert_eq "hop1 inherits cwd" "/abs/proj" "$(echo "$h1" | jq -r '.scope.cwd')"
assert_eq "hop1 inherits loop_budget" "1" "$(echo "$h1" | jq -r '.execution_policy.loop_budget')"
assert_eq "hop2 override claude" "claude" "$(echo "$h2" | jq -r '.executor')"
assert_eq "hop2 inherits cwd" "/abs/proj" "$(echo "$h2" | jq -r '.scope.cwd')"

echo "=== next: wired in order; last hop has none ==="
assert_eq "hop1 next -> hop2 file" "hop-02-hop2.task.yaml" "$(echo "$h1" | jq -r '.next')"
assert_eq "hop2 has no next" "null" "$(echo "$h2" | jq -r '.next // "null"')"

echo "=== hop preserves id/goal/acceptance_criteria ==="
assert_eq "hop1 id" "hop1" "$(echo "$h1" | jq -r '.id')"
assert_eq "hop1 goal" "make thing" "$(echo "$h1" | jq -r '.goal')"
assert_eq "hop1 AC cmd" "test -f thing" "$(echo "$h1" | jq -r '.acceptance_criteria[0].verify.cmd')"

echo "=== malformed spec: no hops -> non-zero, message ==="
BAD="$WORK/nohops.yaml"; printf 'defaults: {executor: claude}\n' > "$BAD"
err="$(_ccs_dispatch_plan_expand "$BAD" "$WORK/bad" 2>&1)"; brc=$?
assert_eq "no-hops rc non-zero" "1" "$brc"
assert_contains "no-hops message" "$err" "hops"

echo "=== non-dict hop -> clean plan: error, no traceback, rc 1 ==="
ND="$WORK/nondict.yaml"; printf 'hops:\n  - "just a string"\n' > "$ND"
nderr="$(_ccs_dispatch_plan_expand "$ND" "$WORK/nd" 2>&1)"; ndrc=$?
assert_eq "non-dict rc 1" "1" "$ndrc"
assert_contains "non-dict clean msg" "$nderr" "plan:"
assert_not_contains "non-dict no traceback" "$nderr" "Traceback"

echo "=== hop id with slash -> clean plan: error, no traceback, rc 1 ==="
SL="$WORK/slashid.yaml"
{ echo "hops:"; echo "  - id: foo/bar"; echo "    goal: g";
  echo "    acceptance_criteria: [{id: AC1, text: t, verify: {cmd: \"true\"}}]"; } > "$SL"
slerr="$(_ccs_dispatch_plan_expand "$SL" "$WORK/sl" 2>&1)"; slrc=$?
assert_eq "slash-id rc 1" "1" "$slrc"
assert_contains "slash-id clean msg" "$slerr" "plan:"
assert_not_contains "slash-id no traceback" "$slerr" "Traceback"

test_summary
