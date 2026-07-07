#!/usr/bin/env bash
# tests/test-dispatch-preview.sh — dispatch preview sign-off gate (#75)
# Units: preview render (fields, long-prompt folding), stdin confirm
# (yes / no / EOF / timeout), and the ccs-dispatch integration: a rejected
# preview leaves no job record and never spawns; --yes keeps automation flows.
# Isolation: XDG_DATA_HOME sandbox; spawn and backend resolution stubbed.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-preview-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

DD="$(_ccs_dispatch_dir)"
JOBS="$DD/jobs.jsonl"
SANDBOX="$SCRIPT_DIR/tmp/test-dispatch-preview"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX/proj"

SPAWN_LOG="$SANDBOX/spawn.log"

# Stub the spawn layer: record the call, never run a real worker.
_ccs_dispatch_spawn() {
  printf '%s\n' "SPAWN job=$1 backend=$6" >> "$SPAWN_LOG"
  return 0
}
# Pin backend resolution so the tests do not depend on host agent-pager state.
_ccs_dispatch_resolve_backend() { echo "headless"; }

reset_case() {
  rm -f "$JOBS" "$SPAWN_LOG"; rm -rf "$DD/results" "$DD/pids"
  mkdir -p "$DD/results" "$DD/pids"
}

echo "=== render: preview block carries the sign-off facts ==="
out="$(_ccs_dispatch_preview_render "/some/proj" "agentpager" "async" 600 "do the thing")"
assert_contains "shows the project" "$out" "project : /some/proj"
assert_contains "shows the backend" "$out" "backend : agentpager"
assert_contains "agentpager backend names its seat" "$out" "local-$(id -un)"
assert_contains "shows mode and timeout" "$out" "async (timeout 600s)"
assert_contains "shows the prompt text" "$out" "do the thing"

echo "=== render: long prompt folds the middle, keeps the task tail ==="
long_prompt="$(printf 'x%.0s' $(seq 1 3000))Task: find me"
out="$(CCS_DISPATCH_PREVIEW_MAX_CHARS=100 _ccs_dispatch_preview_render \
  "/p" "headless" "async" 600 "$long_prompt")"
assert_contains "folded prompt notes the full size" "$out" "of 3013 chars"
assert_not_contains "folded prompt does not dump everything" "$out" \
  "$(printf 'x%.0s' $(seq 1 200))"
assert_contains "the trailing task line survives the fold" "$out" "Task: find me"

echo "=== render: multibyte prompt folds on characters, not bytes ==="
zh_prompt="$(printf '中%.0s' $(seq 1 600))"
out="$(CCS_DISPATCH_PREVIEW_MAX_CHARS=100 _ccs_dispatch_preview_render \
  "/p" "headless" "async" 600 "$zh_prompt")"
assert_contains "head keeps 50 intact characters" "$out" \
  "$(printf '中%.0s' $(seq 1 50))"
assert_contains "fold marker counts characters" "$out" "of 600 chars"

echo "=== confirm: y / Y accept, n / EOF reject ==="
rc=0; echo "y" | _ccs_dispatch_preview_confirm || rc=$?
assert_eq "y accepts" "0" "$rc"
rc=0; echo "YES" | _ccs_dispatch_preview_confirm || rc=$?
assert_eq "YES accepts" "0" "$rc"
rc=0; echo "n" | _ccs_dispatch_preview_confirm || rc=$?
assert_eq "n rejects" "1" "$rc"
rc=0; _ccs_dispatch_preview_confirm </dev/null || rc=$?
assert_eq "EOF (non-interactive caller) rejects" "1" "$rc"

echo "=== confirm: silence times out as a rejection ==="
rc=0; sleep 3 | CCS_DISPATCH_PREVIEW_TIMEOUT=1 _ccs_dispatch_preview_confirm || rc=$?
assert_eq "timeout rejects" "1" "$rc"

echo "=== integration: rejected preview leaves nothing behind ==="
reset_case
rc=0
ccs-dispatch --preview --project "$SANDBOX/proj" "task A" </dev/null >/dev/null 2>&1 || rc=$?
assert_eq "rejected preview returns non-zero" "1" "$rc"
assert_eq "no job record on rejection" "0" "$( [ -f "$JOBS" ] && grep -c '' "$JOBS" || echo 0 )"
assert_eq "spawn never called on rejection" "0" "$( [ -f "$SPAWN_LOG" ] && grep -c '' "$SPAWN_LOG" || echo 0 )"

echo "=== integration: approved preview dispatches ==="
reset_case
out="$(echo y | ccs-dispatch --preview --project "$SANDBOX/proj" "task B" 2>/dev/null)"
assert_contains "preview shown before dispatch" "$out" "dispatch preview"
assert_contains "job dispatched after approval" "$out" "Job dispatched:"
assert_eq "spawn called once" "1" "$(grep -c '' "$SPAWN_LOG")"
assert_eq "job record written" "1" "$(grep -c '"task":"task B"' "$JOBS")"

echo "=== integration: --preview --yes shows but never waits ==="
reset_case
out="$(ccs-dispatch --preview --yes --project "$SANDBOX/proj" "task C" </dev/null 2>/dev/null)"
assert_contains "preview still printed" "$out" "dispatch preview"
assert_eq "spawn called without stdin" "1" "$(grep -c '' "$SPAWN_LOG")"

echo "=== integration: no flags keeps the current behavior ==="
reset_case
out="$(ccs-dispatch --project "$SANDBOX/proj" "task D" </dev/null 2>/dev/null)"
assert_not_contains "no preview block by default" "$out" "dispatch preview"
assert_eq "spawn called directly" "1" "$(grep -c '' "$SPAWN_LOG")"

test_summary
