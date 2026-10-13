#!/usr/bin/env bash
# tests/test-gate-worker-error.sh — worker infra failure is evidence, and the
# deterministic subset of it produces the gate's ERROR verdict (issue #106).
#
# Two separable claims:
#   1. every executor records its exit code (evidence only, no verdict change)
#   2. only failures judged DETERMINISTIC (no retry expected to pass) write
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
for c in claude gemini grok opencode; do
  cat > "$WORK/bin/$c" <<'FAKE'
#!/usr/bin/env bash
echo "$0 $*" >> "$FAKE_CLI_LOG"
# Optional canned output (what a CLI prints when it aborts), followed by
# FAKE_CLI_PAD_AFTER unrelated lines so a test can push it out of a tail window.
[ -n "${FAKE_CLI_OUT:-}" ] && printf '%s\n' "$FAKE_CLI_OUT"
i=0
while [ "$i" -lt "${FAKE_CLI_PAD_AFTER:-0}" ]; do
  echo "unrelated output line $i"
  i=$((i + 1))
done
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

: > "$FAKE_CLI_LOG"
ad="$(spawn 8 0 grok)"
assert_contains "the grok stub actually ran" \
  "$(cat "$FAKE_CLI_LOG")" "/bin/grok -p do X"
assert_eq "grok rc 0 recorded" "0" "$(cat "$ad/executor-exit-code" 2>/dev/null)"

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

echo "=== worker output classification: every string in the table ==="
# classify_case <label> <executor> <exit> <expected|absent> <output> [pad_after]
# Always goes through _ccs_dispatch_run_worker (the wiring is under test, not
# just the classifier), into a fresh run dir so cases cannot see each other.
CLS_N=0
classify_case() {
  local label="$1" executor="$2" code="$3" expected="$4" out="$5" pad="${6:-0}"
  CLS_N=$((CLS_N + 1))
  local run="$WORK/run-cls-$CLS_N"; mkdir -p "$run"
  export FAKE_CLI_EXIT="$code" FAKE_CLI_OUT="$out" FAKE_CLI_PAD_AFTER="$pad"
  _ccs_dispatch_run_worker "$CWD" "do X" "$run" 1 60 "$executor"
  unset FAKE_CLI_EXIT FAKE_CLI_OUT FAKE_CLI_PAD_AFTER
  local got="absent"
  [ -e "$run/attempt-01/worker-error" ] && got="$(cat "$run/attempt-01/worker-error")"
  assert_eq "$label" "$expected" "$got"
}

# Fixtures are mostly observed CLI lines, with machine-specific paths
# rewritten to generic forms; C_AUTH2 and G_AUTH2 are synthetic (those two
# strings were never triggered). Each fixture holds exactly one table string.
C_AUTH='Not logged in · Please run /login'
C_AUTH2='Invalid API key'
C_MODEL1='[claude-code:unrecognized_model] {"model":"no-such-model-x1","query_source":"sdk"}'
C_MODEL2="There's an issue with the selected model (no-such-model-x1). It may not exist or you may not have access to it. Run --model to pick a different model."
G_AUTH='Please set an Auth method in your ~/.gemini/settings.json or specify one of the following environment variables before running: GEMINI_API_KEY, GOOGLE_GENAI_USE_VERTEXAI, GOOGLE_GENAI_USE_GCA'
G_AUTH2='FatalAuthenticationError: authentication required'
G_MODEL='Error when talking to Gemini API Full report available at: <tmp>/gemini-client-error-Turn.run-sendMessageStream.json ModelNotFoundError: Requested entity was not found.'
O_AUTH=$'\e[91m\e[1mError: \e[0mAuthentication Error, No api key passed in.'
O_UNKNOWN=$'\e[91m\e[1mError: \e[0m{\n  "name": "UnknownError",\n  "data": {\n    "message": "Unexpected server error. Check server logs for details.",\n    "ref": "err_x"\n  }\n}'
G_QUOTA='Attempt 1 failed: You have exhausted your capacity on this model. Your quota will reset after 4m57s.. Retrying after 328332ms...'

classify_case "claude 'Not logged in' -> auth" claude 1 auth "$C_AUTH"
classify_case "claude 'Invalid API key' -> auth" claude 1 auth "$C_AUTH2"
classify_case "claude 'unrecognized_model' -> model-not-found" claude 1 model-not-found "$C_MODEL1"
classify_case "claude 'issue with the selected model' -> model-not-found" claude 1 model-not-found "$C_MODEL2"
classify_case "gemini 'Please set an Auth method' (rc 41) -> auth" gemini 41 auth "$G_AUTH"
classify_case "gemini 'FatalAuthenticationError' -> auth" gemini 1 auth "$G_AUTH2"
classify_case "gemini 'ModelNotFoundError' -> model-not-found" gemini 1 model-not-found "$G_MODEL"
classify_case "gemini quota exhaustion is not classified (quota out of scope)" \
  gemini 1 absent "$G_QUOTA"
# The window also holds the model's own reply. Most table strings are
# longer observed fragments, so a reply that merely names the error is not
# classified. Two entries stay keyword-level ("Invalid API key",
# "FatalAuthenticationError"); a reply quoting them exactly is still
# misclassified, and the cases below only guard against loosening them.
classify_case "a reply naming ModelNotFoundError alone is not classified" \
  gemini 53 absent 'Summary: added a handler for ModelNotFoundError in client.py.'
classify_case "a reply quoting 'not logged in' alone is not classified" \
  claude 1 absent 'The helper now prints "not logged in" when the token is missing.'
classify_case "a reply naming unrecognized_model alone is not classified" \
  claude 1 absent 'Added handling for the unrecognized_model error code.'
classify_case "a reply saying 'issue with the selected model' alone is not classified" \
  claude 1 absent 'Logged an issue with the selected model in the tracker.'
classify_case "a reply mentioning the auth method alone is not classified" \
  gemini 1 absent 'Configured the auth method in settings.'
classify_case "a reply mentioning an API key alone is not classified" \
  claude 1 absent 'Rotated the API key in the vault.'

classify_case "opencode auth string -> auth" opencode 1 auth "$O_AUTH"
classify_case "opencode UnknownError is not classified" opencode 1 absent "$O_UNKNOWN"
classify_case "a reply naming Authentication Error alone is not classified" \
  opencode 1 absent 'Added a retry for the Authentication Error path in client.py.'

echo "=== worker output classification: guards ==="
classify_case "rc 0 with an auth string writes nothing" claude 0 absent "$C_AUTH"
classify_case "grok is never classified" grok 1 absent "$C_AUTH"
classify_case "rc 1 with unrelated output writes nothing" claude 1 absent \
  'something went wrong but not in the table'
classify_case "rc 127 outranks the output classification" claude 127 exit-127 "$C_AUTH"
classify_case "rc 124 with an auth string stays unclassified (timeout policy)" \
  claude 124 absent "$C_AUTH"
classify_case "match is case-insensitive" claude 1 auth 'NOT LOGGED IN · PLEASE RUN /LOGIN'
classify_case "auth outranks model-not-found when both are present" claude 1 auth \
  "$C_AUTH"$'\n'"$C_MODEL2"

echo "=== worker output classification: tail window is 50 lines ==="
classify_case "auth line followed by 60 unrelated lines is outside the window" \
  claude 1 absent "$C_AUTH" 60
classify_case "auth line followed by 49 unrelated lines is inside the window" \
  claude 1 auth "$C_AUTH" 49

echo "=== run loop: classified worker errors escalate without a retry ==="
loop_case() {
  local label="$1" out="$2" expected="$3"
  export FAKE_CLI_EXIT=1 FAKE_CLI_OUT="$out"
  local chain hop rc
  chain="$(_ccs_dispatch_run "$task_yaml")"; rc=$?
  unset FAKE_CLI_EXIT FAKE_CLI_OUT
  hop="$chain/hop-01-we-x"
  assert_eq "$label: exit 10 escalated" "10" "$rc"
  assert_eq "$label: one attempt only" "1" "$(jq -r '.attempts' "$hop/final.json")"
  assert_eq "$label: escalation blamed on the worker" "worker_error" \
    "$(jq -r '.escalation.reason' "$hop/final.json")"
  assert_eq "$label: verdict.json carries the class" "$expected" \
    "$(jq -r '.worker_error' "$hop/attempt-01/gate/verdict.json")"
}
loop_case "auth" "$C_AUTH" auth
loop_case "model-not-found" "$C_MODEL2" model-not-found

export FAKE_CLI_EXIT=1 FAKE_CLI_OUT='something went wrong but not in the table'
chain3="$(_ccs_dispatch_run "$task_yaml")"; rc3=$?
unset FAKE_CLI_EXIT FAKE_CLI_OUT
assert_eq "unclassified rc 1 with output still spends its retry" "2" \
  "$(jq -r '.attempts' "$chain3/hop-01-we-x/final.json")"
assert_eq "unclassified rc 1 with output blames the gate" "gate" \
  "$(jq -r '.escalation.reason' "$chain3/hop-01-we-x/final.json")"

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
