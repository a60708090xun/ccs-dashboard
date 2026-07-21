#!/usr/bin/env bash
# tests/test-dispatch-agentpager-cli.sh — ccs-dispatch --cli selector (issue #89).
# Command-level parsing: --cli flag, CCS_DISPATCH_CLI env default, precedence,
# validation, and the headless-backend downgrade warning. The spawn->inbound
# threading itself is covered in test-dispatch-spawn-agentpager.sh.
# Isolation: XDG_DATA_HOME sandbox; the spawn dispatcher is overridden to capture
# the cli argument instead of running the real backend.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-agentpager-cli-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

DD="$(_ccs_dispatch_dir)"
JOBS="$DD/jobs.jsonl"
reset_jobs() { rm -f "$JOBS"; rm -rf "$DD/results" "$DD/pids"; mkdir -p "$DD/results" "$DD/pids"; }

PROJ="$SCRIPT_DIR/tmp/test-ap-cli-proj"; mkdir -p "$PROJ"
CAP="$SCRIPT_DIR/tmp/test-ap-cli-spawn.cli"

# Capture the cli argument ccs-dispatch passes to the spawn dispatcher (slot 9),
# instead of running the real backend. rc 0 so ccs-dispatch reports success.
_ccs_dispatch_spawn() { printf '%s' "${9:-}" > "$CAP"; return 0; }

echo "=== --cli gemini is threaded to the spawn dispatcher ==="
reset_jobs; : > "$CAP"
CCS_DISPATCH_BACKEND=agentpager ccs-dispatch --cli gemini --project "$PROJ" --yes "t" >/dev/null 2>&1
assert_eq "flag selects gemini" "gemini" "$(cat "$CAP")"

echo "=== default cli is claude ==="
reset_jobs; : > "$CAP"
CCS_DISPATCH_BACKEND=agentpager ccs-dispatch --project "$PROJ" --yes "t" >/dev/null 2>&1
assert_eq "no flag -> claude" "claude" "$(cat "$CAP")"

echo "=== CCS_DISPATCH_CLI env sets the default ==="
reset_jobs; : > "$CAP"
CCS_DISPATCH_BACKEND=agentpager CCS_DISPATCH_CLI=gemini \
  ccs-dispatch --project "$PROJ" --yes "t" >/dev/null 2>&1
assert_eq "env selects gemini" "gemini" "$(cat "$CAP")"

echo "=== flag overrides env ==="
reset_jobs; : > "$CAP"
CCS_DISPATCH_BACKEND=agentpager CCS_DISPATCH_CLI=gemini \
  ccs-dispatch --cli claude --project "$PROJ" --yes "t" >/dev/null 2>&1
assert_eq "flag beats env" "claude" "$(cat "$CAP")"

echo "=== invalid --cli aborts before any side effect ==="
reset_jobs; : > "$CAP"
before=$([ -f "$JOBS" ] && wc -l < "$JOBS" || echo 0)
rc=0
err="$(CCS_DISPATCH_BACKEND=agentpager ccs-dispatch --cli bogus --project "$PROJ" --yes "t" 2>&1 >/dev/null)" || rc=$?
assert_eq "invalid --cli -> rc 1" "1" "$rc"
assert_contains "error names the --cli flag" "$err" "cli"
assert_eq "spawn not called on invalid cli" "" "$(cat "$CAP")"
after=$([ -f "$JOBS" ] && wc -l < "$JOBS" || echo 0)
assert_eq "no job record written on invalid cli" "$before" "$after"

echo "=== --cli gemini on headless warns and downgrades to claude ==="
reset_jobs; : > "$CAP"
warn="$(CCS_DISPATCH_BACKEND=headless ccs-dispatch --cli gemini --project "$PROJ" --yes "t" 2>&1 >/dev/null)"
assert_contains "headless --cli emits a warning" "$warn" "cli"
assert_eq "headless downgrades to claude" "claude" "$(cat "$CAP")"

rm -rf "$PROJ"; rm -f "$CAP"
test_summary
