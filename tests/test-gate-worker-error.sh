#!/usr/bin/env bash
# tests/test-gate-worker-error.sh — worker infra failure is evidence, and the
# deterministic subset of it produces the gate's ERROR verdict (issue #106).
#
# Two separable claims:
#   1. every executor records its exit code (evidence only, no verdict change)
#   2. only DETERMINISTIC failures (a retry provably cannot pass) write
#      attempt-NN/worker-error, which the gate turns into ERROR -> ESCALATE
#      without spending a retry on infrastructure
# A timeout (124) and a plain non-zero (1) stay on the FAIL -> RETRY path on
# purpose: those can self-heal on attempt 2, and the fix must not trade that
# away. Absence of worker-error is fail-open (identical to today's behaviour).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-worker-error-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-worker-error"; rm -rf "$WORK"
mkdir -p "$WORK/repo" "$WORK/bin"; _TEST_DIRS+=("$WORK")

# Fake CLIs on PATH (precedent: test-dispatch-executor-cli.sh). The exit code
# comes from FAKE_CLI_EXIT so a "crash" is deterministic: 125/126/127 stand in
# for timeout-itself-failed / not-executable / not-found, which in the real
# world are produced by `timeout` and the shell rather than by the CLI.
for c in claude gemini; do
  cat > "$WORK/bin/$c" <<'FAKE'
#!/usr/bin/env bash
echo "$0 $*" >> "$FAKE_CLI_LOG"
exit "${FAKE_CLI_EXIT:-0}"
FAKE
  chmod +x "$WORK/bin/$c"
done
export PATH="$WORK/bin:$PATH"
export FAKE_CLI_LOG="$WORK/argv.log"

CWD="$WORK/repo"; (cd "$CWD" && git init -q)
RUN="$WORK/run"; mkdir -p "$RUN"

# spawn <attempt> <exit_code> [executor] -> attempt dir path. FAKE_CLI_EXIT is
# exported (the stub is a child process) and scoped by the command substitution.
spawn() {
  local attempt="$1" code="$2" executor="${3:-claude}"
  export FAKE_CLI_EXIT="$code"
  _ccs_dispatch_run_worker "$CWD" "do X" "$RUN" "$attempt" 60 "$executor"
  printf '%s\n' "$RUN/attempt-$(printf '%02d' "$attempt")"
}

echo "=== every executor records its exit code (evidence) ==="
: > "$FAKE_CLI_LOG"
ad="$(spawn 1 0 claude)"
assert_contains "the stub actually ran (rc 0 proves nothing on its own)" \
  "$(cat "$FAKE_CLI_LOG")" "/bin/claude -p do X"
assert_eq "claude rc 0 recorded" "0" "$(cat "$ad/executor-exit-code" 2>/dev/null)"
assert_eq "clean run writes no worker-error" "absent" \
  "$([ -e "$ad/worker-error" ] && echo present || echo absent)"

: > "$FAKE_CLI_LOG"
ad="$(spawn 2 0 gemini)"
assert_contains "the gemini stub actually ran" \
  "$(cat "$FAKE_CLI_LOG")" "/bin/gemini -p do X"
assert_eq "gemini rc 0 recorded" "0" "$(cat "$ad/executor-exit-code" 2>/dev/null)"

echo "=== non-deterministic failures stay on the FAIL -> RETRY path ==="
ad="$(spawn 3 1 claude)"
assert_eq "rc 1 recorded" "1" "$(cat "$ad/executor-exit-code" 2>/dev/null)"
assert_eq "rc 1 writes no worker-error" "absent" \
  "$([ -e "$ad/worker-error" ] && echo present || echo absent)"

ad="$(spawn 4 124 claude)"
assert_eq "timeout rc 124 recorded" "124" "$(cat "$ad/executor-exit-code" 2>/dev/null)"
assert_eq "timeout writes no worker-error (can self-heal)" "absent" \
  "$([ -e "$ad/worker-error" ] && echo present || echo absent)"

echo "=== deterministic failures write worker-error ==="
ad="$(spawn 5 125 claude)"
assert_eq "125 -> exit-125" "exit-125" "$(cat "$ad/worker-error" 2>/dev/null)"
ad="$(spawn 6 126 claude)"
assert_eq "126 -> exit-126" "exit-126" "$(cat "$ad/worker-error" 2>/dev/null)"
ad="$(spawn 7 127 gemini)"
assert_eq "127 -> exit-127" "exit-127" "$(cat "$ad/worker-error" 2>/dev/null)"
assert_eq "127 rc also recorded" "127" "$(cat "$ad/executor-exit-code" 2>/dev/null)"

echo "=== gate turns worker-error into ERROR -> ESCALATE, not RETRY ==="
task='{"id":"t","goal":"g","acceptance_criteria":[
  {"id":"AC1","text":"missing","verify":{"cmd":"grep -q greet greeter.py"}}]}'

att="$WORK/att-err"; mkdir -p "$att"; printf 'exit-127\n' > "$att/worker-error"
v="$(_ccs_dispatch_gate_run "$CWD" "$task" "$att" 1 1)"
assert_eq "attempt 1 of budget 1 escalates" "ESCALATE" "$v"
assert_eq "verdict.json agrees" "ESCALATE" "$(jq -r '.verdict' "$att/gate/verdict.json")"
assert_eq "verdict records the kind" "exit-127" \
  "$(jq -r '.worker_error' "$att/gate/verdict.json")"
assert_eq "AC evidence still collected" "FAIL" "$(jq -r '.verdict' "$att/gate/AC1.json")"
assert_eq "no synthetic AC file (would collide with a user AC id)" "absent" \
  "$([ -e "$att/gate/_worker.json" ] && echo present || echo absent)"

echo "=== fail-open: no worker-error -> unchanged RETRY ==="
att2="$WORK/att-ok"; mkdir -p "$att2"
v2="$(_ccs_dispatch_gate_run "$CWD" "$task" "$att2" 1 1)"
assert_eq "same inputs without worker-error retry" "RETRY" "$v2"
# has() rather than a null read: an absent field also prints "null", so the
# value check alone cannot tell "written as null" from "never added".
assert_eq "worker_error field is present" "true" \
  "$(jq -r 'has("worker_error")' "$att2/gate/verdict.json")"
assert_eq "worker_error is null" "null" \
  "$(jq -r '.worker_error' "$att2/gate/verdict.json")"

echo "=== ERROR outranks a passing AC set ==="
echo "def greet(name): pass" > "$CWD/greeter.py"
att3="$WORK/att-pass"; mkdir -p "$att3"; printf 'exit-126\n' > "$att3/worker-error"
v3="$(_ccs_dispatch_gate_run "$CWD" "$task" "$att3" 1 1)"
assert_eq "worker never ran -> escalate even though ACs pass" "ESCALATE" "$v3"
rm -f "$CWD/greeter.py"

echo "=== run loop: deterministic failure escalates without spending a retry ==="
task_yaml="$WORK/task.yaml"
cat > "$task_yaml" <<YAML
id: we-x
goal: "create greeter.py with greet()"
scope:
  cwd: "$CWD"
execution_policy:
  loop_budget: 1
  timeout_sec: 60
acceptance_criteria:
  - id: AC1
    text: "greet exists"
    verify:
      cmd: "grep -q 'def greet' greeter.py"
YAML

export FAKE_CLI_EXIT=127
chain="$(_ccs_dispatch_run "$task_yaml")"; rc=$?
hop="$chain/hop-01-we-x"
assert_eq "exit 10 escalated" "10" "$rc"
assert_eq "one attempt only" "1" "$(jq -r '.attempts' "$hop/final.json")"
assert_eq "outcome escalated" "escalated" "$(jq -r '.outcome' "$hop/final.json")"
assert_eq "final.json carries worker_rc" "127" "$(jq -r '.worker_rc' "$hop/final.json")"
assert_eq "escalation blamed on the worker" "worker_error" \
  "$(jq -r '.escalation.reason' "$hop/final.json")"

echo "=== run loop: a plain failure still spends its retry and blames the gate ==="
export FAKE_CLI_EXIT=1
chain2="$(_ccs_dispatch_run "$task_yaml")"; rc2=$?
hop2="$chain2/hop-01-we-x"
assert_eq "exit 10 escalated" "10" "$rc2"
assert_eq "two attempts" "2" "$(jq -r '.attempts' "$hop2/final.json")"
assert_eq "final.json carries worker_rc" "1" "$(jq -r '.worker_rc' "$hop2/final.json")"
assert_eq "escalation blamed on the gate" "gate" \
  "$(jq -r '.escalation.reason' "$hop2/final.json")"

echo "=== agentpager: deterministic infra failures are classified too ==="
unset FAKE_CLI_EXIT
_ccs_dispatch_agentpager_available() { return 1; }
ad="$RUN/attempt-08"
_ccs_dispatch_run_worker "$CWD" "do X" "$RUN" 8 60 claude "" agentpager
assert_eq "daemon down classified" "agentpager-daemon-down" \
  "$(cat "$ad/worker-error" 2>/dev/null)"
assert_eq "human-readable note kept" "present" \
  "$([ -s "$ad/agentpager-error.txt" ] && echo present || echo absent)"

_ccs_dispatch_agentpager_available() { return 0; }
_ccs_dispatch_resolve_proj_from_dir() { return 1; }
_ccs_dispatch_run_worker "$CWD" "do X" "$RUN" 9 60 claude "" agentpager
assert_eq "no proj-map entry classified" "agentpager-no-proj-map" \
  "$(cat "$RUN/attempt-09/worker-error" 2>/dev/null)"

_ccs_dispatch_resolve_proj_from_dir() { echo "ccs-dashboard"; return 0; }
_ccs_dispatch_agentpager_session_alive() { return 0; }
_ccs_dispatch_run_worker "$CWD" "do X" "$RUN" 10 60 claude "" agentpager
assert_eq "seat busy is transient, not classified" "absent" \
  "$([ -e "$RUN/attempt-10/worker-error" ] && echo present || echo absent)"

test_summary
