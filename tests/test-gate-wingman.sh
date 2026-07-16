#!/usr/bin/env bash
# tests/test-gate-wingman.sh — wingman executor: plan passthrough, evidence,
# gate sovereignty, no-retry clamp. Uses a fake `wingman` binary on PATH
# (precedent: tmp/fake-gemini) driven by env vars.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-wingman-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-wingman"
rm -rf "$WORK"; mkdir -p "$WORK/repo" "$WORK/bin"; _TEST_DIRS+=("$WORK")
WORK="$(realpath "$WORK")"   # match realpath -m used by plan resolution

# Fake wingman: logs cwd + argv per call, optionally edits the repo and always
# writes .wingman/result.md; exit code comes from FAKE_WINGMAN_EXIT.
cat > "$WORK/bin/wingman" <<'FAKE'
#!/usr/bin/env bash
echo "$PWD|$*" >> "$FAKE_WINGMAN_LOG"
mkdir -p .wingman
printf 'overall_status: %s\n' "$FAKE_WINGMAN_STATUS" > .wingman/result.md
[ -n "${FAKE_WINGMAN_WRITE:-}" ] && echo "def greet(name): pass" > greeter.py
exit "$FAKE_WINGMAN_EXIT"
FAKE
chmod +x "$WORK/bin/wingman"
export PATH="$WORK/bin:$PATH"
export FAKE_WINGMAN_LOG="$WORK/calls.log"

mk_task() {  # mk_task <budget>
  cat > "$WORK/task.yaml" <<YAML
id: wg-x
goal: "create greeter.py with greet()"
executor: wingman
plan: "plan.md"
scope:
  cwd: "$WORK/repo"
execution_policy:
  loop_budget: $1
acceptance_criteria:
  - id: AC1
    text: "greet exists"
    verify:
      cmd: "grep -q 'def greet' greeter.py"
YAML
  echo "local plan for wg-x" > "$WORK/plan.md"
}

echo "=== validation: wingman + plan loads; plan field parsed ==="
mk_task 1
js="$(_ccs_dispatch_gate_load_task "$WORK/task.yaml")"; rc=$?
assert_eq "wingman+plan rc 0" "0" "$rc"
assert_eq "plan parsed" "plan.md" "$(echo "$js" | jq -r '.plan')"

echo "=== validation: wingman without plan -> rc 1 ==="
grep -v '^plan:' "$WORK/task.yaml" > "$WORK/noplan.yaml"
_ccs_dispatch_gate_load_task "$WORK/noplan.yaml" >/dev/null 2>&1
assert_eq "wingman no plan -> rc 1" "1" "$?"

echo "=== validation: plan with non-wingman executor -> rc 1 ==="
sed 's/^executor: wingman/executor: claude/' "$WORK/task.yaml" > "$WORK/planclaude.yaml"
_ccs_dispatch_gate_load_task "$WORK/planclaude.yaml" >/dev/null 2>&1
assert_eq "plan+claude -> rc 1" "1" "$?"
grep -v '^executor:' "$WORK/task.yaml" > "$WORK/plannoexec.yaml"
_ccs_dispatch_gate_load_task "$WORK/plannoexec.yaml" >/dev/null 2>&1
assert_eq "plan+omitted executor -> rc 1" "1" "$?"

echo "=== e2e PASS: spawn cmd, cwd, evidence, exit-code file ==="
mk_task 1
: > "$FAKE_WINGMAN_LOG"
export FAKE_WINGMAN_STATUS="done" FAKE_WINGMAN_EXIT=0 FAKE_WINGMAN_WRITE=1
chain_dir="$(_ccs_dispatch_run "$WORK/task.yaml")"; rc=$?
hop="$chain_dir/hop-01-wg-x"
assert_eq "exit 0 accepted" "0" "$rc"
assert_eq "outcome accepted" "accepted" "$(jq -r '.outcome' "$hop/final.json")"
assert_eq "one call" "1" "$(wc -l < "$FAKE_WINGMAN_LOG")"
assert_eq "cwd is scope.cwd" "$WORK/repo" "$(cut -d'|' -f1 "$FAKE_WINGMAN_LOG")"
assert_eq "argv passthrough" \
  "execute --plan $WORK/plan.md --exit-status" \
  "$(cut -d'|' -f2 "$FAKE_WINGMAN_LOG")"
assert_eq "result.md frozen" "overall_status: done" \
  "$(cat "$hop/attempt-01/wingman-result.md")"
assert_eq "exit code recorded" "0" "$(cat "$hop/attempt-01/executor-exit-code")"

echo "=== gate sovereign + no-retry clamp: exit 0, AC fails, budget 2 ==="
rm -f "$WORK/repo/greeter.py"; : > "$FAKE_WINGMAN_LOG"
mk_task 2
export FAKE_WINGMAN_STATUS="done" FAKE_WINGMAN_EXIT=0; unset FAKE_WINGMAN_WRITE
chain_dir2="$(_ccs_dispatch_run "$WORK/task.yaml")"; rc2=$?
hop2="$chain_dir2/hop-01-wg-x"
assert_eq "exit 10 escalated" "10" "$rc2"
assert_eq "outcome escalated" "escalated" "$(jq -r '.outcome' "$hop2/final.json")"
assert_eq "attempts clamped to 1" "1" "$(jq -r '.attempts' "$hop2/final.json")"
assert_eq "single spawn despite budget 2" "1" "$(wc -l < "$FAKE_WINGMAN_LOG")"

echo "=== gate sovereign over pessimistic self-report: exit 11, AC passes ==="
: > "$FAKE_WINGMAN_LOG"
mk_task 1
export FAKE_WINGMAN_STATUS="escalate_needed" FAKE_WINGMAN_EXIT=11 FAKE_WINGMAN_WRITE=1
chain_dir3="$(_ccs_dispatch_run "$WORK/task.yaml")"; rc3=$?
hop3="$chain_dir3/hop-01-wg-x"
assert_eq "exit 0 accepted (gate wins)" "0" "$rc3"
assert_eq "outcome accepted" "accepted" "$(jq -r '.outcome' "$hop3/final.json")"
assert_eq "exit 11 recorded as evidence" "11" \
  "$(cat "$hop3/attempt-01/executor-exit-code")"

test_summary
