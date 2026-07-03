#!/usr/bin/env bash
# tests/test-jobs-agentpager.sh — ccs-jobs agentpager board integration (Task 3)
# Units: sync_status (bug1 reduce-merge, bug2 session-aware, tiebreak),
# list last-activity footer, single-view handoff-ready hint.
# Isolation: XDG_DATA_HOME sandbox + AGENT_PAGER_DIR sandbox; tmux mocked via
# overriding _ccs_dispatch_agentpager_session_alive.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Sandbox the data dir BEFORE sourcing anything that resolves it.
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-jobs-ap-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

RS=$'\x1e'; US=$'\x1f'
DD="$(_ccs_dispatch_dir)"           # sandboxed dispatch dir
JOBS="$DD/jobs.jsonl"

# reset_jobs — start each unit from a clean jobs.jsonl + results/pids
reset_jobs() {
  rm -f "$JOBS"; rm -rf "$DD/results" "$DD/pids"
  mkdir -p "$DD/results" "$DD/pids"
}

# append a raw jsonl line (helper keeps tests terse)
jrec() { printf '%s\n' "$1" >> "$JOBS"; }

echo "=== sync bug1: fallback marker (no status) still resolves to running ==="
reset_jobs
# agentpager job that fell back to headless: running record + fallback marker
# (fallback marker has NO status field, so tail -1 would misread it as null).
jrec '{"job_id":"d-b1","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
jrec '{"job_id":"d-b1","backend":"headless","fallback":true}'
# no pidfile, no md -> a dead headless process must be reconciled to failed.
_ccs_jobs_sync_status
b1=$(_ccs_dispatch_jsonl_latest "d-b1" | jq -r '.status')
assert_eq "fallback job with dead process -> failed (not skipped)" "failed" "$b1"

echo "=== sync bug2: agentpager running, monitor pid dead but session alive -> stays running ==="
reset_jobs
jrec '{"job_id":"d-b2","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
echo 999999 > "$DD/pids/d-b2.pid"   # a dead pid (monitor gone)
_ccs_dispatch_agentpager_session_alive() { return 0; }   # worker session alive
_ccs_jobs_sync_status
b2=$(_ccs_dispatch_jsonl_latest "d-b2" | jq -r '.status')
assert_eq "agentpager session alive -> still running (not failed)" "running" "$b2"

echo "=== sync bug2: agentpager running, session gone, no md -> completed(note) ==="
reset_jobs
jrec '{"job_id":"d-b3","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
_ccs_dispatch_agentpager_session_alive() { return 1; }   # session gone
_ccs_jobs_sync_status
b3=$(_ccs_dispatch_jsonl_latest "d-b3")
assert_eq "session gone + no md -> completed" "completed" "$(echo "$b3" | jq -r '.status')"
assert_contains "completed carries a monitor-exit note" \
  "$(echo "$b3" | jq -r '.note // ""')" "monitor exited"

echo "=== sync bug2: agentpager running, session gone but md exists -> untouched ==="
reset_jobs
jrec '{"job_id":"d-b4","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
printf '# md\n' > "$DD/results/d-b4.md"   # monitor already finalized (md present)
before=$(wc -l < "$JOBS")
_ccs_dispatch_agentpager_session_alive() { return 1; }
_ccs_jobs_sync_status
after=$(wc -l < "$JOBS")
assert_eq "md present -> sync appends nothing" "$before" "$after"

echo "=== sync tiebreak: only newest running agentpager owns the live session ==="
reset_jobs
jrec '{"job_id":"d-old","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T09:00:00+08:00"}'
jrec '{"job_id":"d-new","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T11:00:00+08:00"}'
_ccs_dispatch_agentpager_session_alive() { return 0; }   # a session is alive
_ccs_jobs_sync_status
assert_eq "newest running agentpager stays running" "running" \
  "$(_ccs_dispatch_jsonl_latest "d-new" | jq -r '.status')"
assert_eq "older running agentpager -> completed (superseded)" "completed" \
  "$(_ccs_dispatch_jsonl_latest "d-old" | jq -r '.status')"
assert_contains "older carries a superseded note" \
  "$(_ccs_dispatch_jsonl_latest "d-old" | jq -r '.note // ""')" "superseded"

echo "=== sync: headless branch unchanged (control) ==="
reset_jobs
jrec '{"job_id":"d-hl","project":"p","backend":"headless","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
echo 999999 > "$DD/pids/d-hl.pid"   # dead pid, no md
_ccs_jobs_sync_status
assert_eq "headless dead pid + no md -> failed" "failed" \
  "$(_ccs_dispatch_jsonl_latest "d-hl" | jq -r '.status')"

test_summary
