#!/usr/bin/env bash
# tests/test-gate-timeout-split.sh — worker and AC timeouts are separable.
#
# execution_policy.worker_timeout_sec bounds the worker, ac_timeout_sec bounds
# each AC; both fall back to timeout_sec, then CCS_DISPATCH_TIMEOUT. The loader
# accepts only null / positive integers for the two new fields.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-timeout-split-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-timeout-split"; rm -rf "$WORK"
mkdir -p "$WORK/repo"; _TEST_DIRS+=("$WORK")
CWD="$WORK/repo"

# mk_task <name> <execution_policy yaml lines, already indented> <ac cmd>
mk_task() {
  local f="$WORK/$1.task.yaml"
  {
    echo "id: t-$1"
    echo "goal: g"
    echo "scope:"
    echo "  cwd: $CWD"
    [ -n "$2" ] && { echo "execution_policy:"; printf '%s\n' "$2"; }
    echo "acceptance_criteria:"
    echo "  - id: AC1"
    echo "    text: t"
    echo "    verify:"
    echo "      cmd: \"$3\""
  } > "$f"
  echo "$f"
}

# Seam: record the timeout argument (5th) the gate hands to the worker.
SEEN="$WORK/seen-timeout"
_ccs_dispatch_run_worker() { printf '%s' "$5" > "$SEEN"; }

# worker_seen <task.yaml> -> timeout the worker received
worker_seen() {
  local y="$1" task hop
  task="$(_ccs_dispatch_gate_load_task "$y")" || { echo "LOAD-FAILED"; return; }
  hop="$WORK/hop-$(basename "$y" .task.yaml)"; rm -rf "$hop"; : > "$SEEN"
  _ccs_dispatch_run_one "$task" "$y" "$hop" >/dev/null
  cat "$SEEN"
}

# ac_record <task.yaml> -> gate/AC1.json path after one gate run
ac_record() {
  local y="$1" task ad
  task="$(_ccs_dispatch_gate_load_task "$y")" || return 1
  ad="$WORK/att-$(basename "$y" .task.yaml)"; rm -rf "$ad"; mkdir -p "$ad"
  _ccs_dispatch_gate_run "$CWD" "$task" "$ad" 1 0 >/dev/null
  echo "$ad/gate/AC1.json"
}

echo "=== AC2.1: worker gets worker_timeout_sec, not timeout_sec ==="
y="$(mk_task w7 $'  worker_timeout_sec: 7\n  timeout_sec: 60' 'true')"
assert_eq "worker_timeout_sec 7 beats timeout_sec 60" "7" "$(worker_seen "$y")"
y="$(mk_task w-only-ts $'  timeout_sec: 60' 'true')"
assert_eq "no worker_timeout_sec -> falls back to timeout_sec 60" "60" "$(worker_seen "$y")"
y="$(mk_task w-none '' 'true')"
assert_eq "neither field -> CCS_DISPATCH_TIMEOUT" "$CCS_DISPATCH_TIMEOUT" "$(worker_seen "$y")"
y="$(mk_task w-ac-only $'  ac_timeout_sec: 1\n  timeout_sec: 60' 'true')"
assert_eq "ac_timeout_sec alone does not leak into worker" "60" "$(worker_seen "$y")"

echo "=== AC2.2: ac_timeout_sec bounds the AC, timeout_sec does not ==="
y="$(mk_task ac1 $'  ac_timeout_sec: 1\n  timeout_sec: 60' 'sleep 3')"
rec="$(ac_record "$y")"
assert_eq "ac_timeout_sec 1 + sleep 3 -> FAIL" "FAIL" "$(jq -r '.verdict' "$rec")"
assert_eq "ac_timeout_sec 1 + sleep 3 -> exit 124" "124" "$(jq -r '.exit_code' "$rec")"
y="$(mk_task ac1-ctrl $'  timeout_sec: 60' 'sleep 3')"
rec="$(ac_record "$y")"
assert_eq "control without ac_timeout_sec: sleep 3 -> PASS" "PASS" "$(jq -r '.verdict' "$rec")"
y="$(mk_task w1-ac $'  worker_timeout_sec: 1\n  timeout_sec: 60' 'sleep 3')"
rec="$(ac_record "$y")"
assert_eq "worker_timeout_sec 1 does not leak into the AC: sleep 3 -> PASS" "PASS" \
  "$(jq -r '.verdict' "$rec")"

echo "=== AC2.3: timeout_sec alone bounds worker and AC ==="
y="$(mk_task only5 $'  timeout_sec: 5' 'sleep 1')"
assert_eq "worker receives 5" "5" "$(worker_seen "$y")"
rec="$(ac_record "$y")"
assert_eq "timeout_sec 5 + sleep 1 -> PASS" "PASS" "$(jq -r '.verdict' "$rec")"
y="$(mk_task only5b $'  timeout_sec: 5' 'sleep 7')"
rec="$(ac_record "$y")"
assert_eq "timeout_sec 5 + sleep 7 -> FAIL" "FAIL" "$(jq -r '.verdict' "$rec")"
assert_eq "timeout_sec 5 + sleep 7 -> exit 124" "124" "$(jq -r '.exit_code' "$rec")"

echo "=== AC2.4: loader accepts only null / positive integer ==="
for field in worker_timeout_sec ac_timeout_sec; do
  for bad in '"abc"' 0 -1 1.5 30.0; do
    y="$(mk_task "bad-$field" "  $field: $bad" 'true')"
    _ccs_dispatch_gate_load_task "$y" >/dev/null 2>&1; rc=$?
    assert_eq "$field: $bad rejected (rc 1)" "1" "$rc"
  done
  y="$(mk_task "ok-$field" "  $field: 30" 'true')"
  _ccs_dispatch_gate_load_task "$y" >/dev/null 2>&1; rc=$?
  assert_eq "$field: 30 accepted (rc 0)" "0" "$rc"
  y="$(mk_task "null-$field" "  $field: null" 'true')"
  _ccs_dispatch_gate_load_task "$y" >/dev/null 2>&1; rc=$?
  assert_eq "$field: null accepted (rc 0)" "0" "$rc"
done
y="$(mk_task ts-abc '  timeout_sec: "abc"' 'true')"
_ccs_dispatch_gate_load_task "$y" >/dev/null 2>&1; rc=$?
assert_eq "timeout_sec stays unvalidated (pre-existing, rc 0)" "0" "$rc"
# A non-object execution_policy was accepted before this change; the new
# field checks only apply inside an object, so it still is.
y="$WORK/ep-scalar.task.yaml"
printf 'id: t-ep\ngoal: g\nscope:\n  cwd: %s\nexecution_policy: 5\n' "$CWD" > "$y"
printf 'acceptance_criteria:\n  - id: AC1\n    text: t\n    verify:\n      cmd: "true"\n' >> "$y"
_ccs_dispatch_gate_load_task "$y" >/dev/null 2>&1; rc=$?
assert_eq "non-object execution_policy still accepted (rc 0)" "0" "$rc"

test_summary
