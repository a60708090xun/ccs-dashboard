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

echo "=== sync: agentpager with a LIVE monitor is deferred to (no startup race) ==="
reset_jobs
jrec '{"job_id":"d-mon","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
echo $$ > "$DD/pids/d-mon.pid"   # live monitor (this shell's pid)
_ccs_dispatch_agentpager_session_alive() { return 1; }  # worker session not up yet (startup lag)
_ccs_jobs_sync_status
assert_eq "live monitor + session-not-yet-up -> still running (no premature complete)" "running" \
  "$(_ccs_dispatch_jsonl_latest "d-mon" | jq -r '.status')"

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

echo "=== sync tiebreak: stale older agentpager with md present is left untouched ==="
reset_jobs
jrec '{"job_id":"d-oldmd","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T09:00:00+08:00"}'
jrec '{"job_id":"d-newmd","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T11:00:00+08:00"}'
printf '# md\n' > "$DD/results/d-oldmd.md"   # older already finalized md (partial finalize)
_ccs_dispatch_agentpager_session_alive() { return 0; }
_ccs_jobs_sync_status
# md present -> defer to the monitor, do not append a misleading superseded record
assert_eq "older-with-md is not overwritten to completed" "running" \
  "$(_ccs_dispatch_jsonl_latest "d-oldmd" | jq -r '.status')"
assert_eq "newest still running" "running" \
  "$(_ccs_dispatch_jsonl_latest "d-newmd" | jq -r '.status')"

echo "=== sync: headless branch unchanged (control) ==="
reset_jobs
jrec '{"job_id":"d-hl","project":"p","backend":"headless","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
echo 999999 > "$DD/pids/d-hl.pid"   # dead pid, no md
_ccs_jobs_sync_status
assert_eq "headless dead pid + no md -> failed" "failed" \
  "$(_ccs_dispatch_jsonl_latest "d-hl" | jq -r '.status')"

echo "=== list footer: running agentpager worker shows last-activity ==="
reset_jobs
export AGENT_PAGER_DIR="$SCRIPT_DIR/tmp/test-jobs-ap-pager"
rm -rf "$AGENT_PAGER_DIR"
mkdir -p "$AGENT_PAGER_DIR/channels/local-$(id -un)"
printf 'frame' > "$AGENT_PAGER_DIR/channels/local-$(id -un)/out.stream"
touch_minutes_ago "$AGENT_PAGER_DIR/channels/local-$(id -un)/out.stream" 3
jrec '{"job_id":"d-foot","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
echo $$ > "$DD/pids/d-foot.pid"    # live pid so sync keeps it running (agentpager uses session)
_ccs_dispatch_agentpager_session_alive() { return 0; }
foot_out="$(ccs-jobs 2>/dev/null)"
assert_contains "footer names the local worker" "$foot_out" "local worker: last activity"
assert_contains "footer shows a 3m-ago idle" "$foot_out" "3m ago"

echo "=== list footer: no running agentpager worker -> no footer ==="
reset_jobs
jrec '{"job_id":"d-done","project":"p","backend":"agentpager","status":"handoff-ready","created_at":"2026-07-03T10:00:00+08:00","finished_at":"2026-07-03T10:05:00+08:00"}'
nofoot="$(ccs-jobs 2>/dev/null)"
assert_not_contains "no running worker -> no footer" "$nofoot" "local worker:"

echo "=== list footer: running worker but stream absent -> no output yet ==="
reset_jobs
rm -rf "$AGENT_PAGER_DIR"; mkdir -p "$AGENT_PAGER_DIR/inbound"
jrec '{"job_id":"d-nostrm","project":"p","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
_ccs_dispatch_agentpager_session_alive() { return 0; }
nos="$(ccs-jobs 2>/dev/null)"
assert_contains "no stream yet -> no output yet footer" "$nos" "local worker: no output yet"
unset AGENT_PAGER_DIR

echo "=== single view: handoff-ready job shows chain hint ==="
reset_jobs
jrec '{"job_id":"d-hr","project":"ccs-dashboard","backend":"agentpager","status":"running","created_at":"2026-07-03T10:00:00+08:00"}'
jrec '{"job_id":"d-hr","status":"handoff-ready","handoff":true,"finished_at":"2026-07-03T10:05:00+08:00"}'
printf '# Dispatch Result: d-hr\n- **Status:** handoff-ready\n' > "$DD/results/d-hr.md"
hr_out="$(ccs-jobs d-hr 2>/dev/null)"
assert_contains "hint points to the .handoff file" "$hr_out" "results/d-hr.handoff"
assert_contains "hint gives a chain command with the project" "$hr_out" \
  'ccs-dispatch --project ccs-dashboard'
assert_contains "hint marks auto-chaining as v2" "$hr_out" "auto-chaining is v2"

echo "=== single view: non-handoff-ready job shows no hint ==="
reset_jobs
jrec '{"job_id":"d-cp","project":"p","backend":"headless","status":"completed","created_at":"2026-07-03T10:00:00+08:00","finished_at":"2026-07-03T10:05:00+08:00"}'
printf '# Dispatch Result: d-cp\n- **Status:** completed\n' > "$DD/results/d-cp.md"
cp_out="$(ccs-jobs d-cp 2>/dev/null)"
assert_not_contains "completed job -> no chain hint" "$cp_out" "auto-chaining is v2"

echo "=== single view: default is slim (summary + pointer, no full output) ==="
reset_jobs
jrec '{"job_id":"d-slim","project":"p","backend":"headless","status":"completed","exit_code":0,"summary":"did the thing in one line","created_at":"2026-07-03T10:00:00+08:00","finished_at":"2026-07-03T10:05:00+08:00"}'
{ printf '# Dispatch Result: d-slim\n## Output\n'; head -c 40000 /dev/zero | tr '\0' 'x'; } > "$DD/results/d-slim.md"
def_out="$(ccs-jobs d-slim 2>/dev/null)"
assert_contains "default shows the one-line summary" "$def_out" "did the thing in one line"
assert_contains "default points at the full artifact" "$def_out" "results/d-slim.md"
assert_not_contains "default does NOT inline the 40KB output" "$def_out" "xxxxxxxxxx"
# Payload must be decoupled from artifact size.
def_bytes=$(printf '%s' "$def_out" | wc -c)
if [ "$def_bytes" -lt 2000 ]; then
  printf '  PASS: default payload stays small (%s bytes vs 40KB artifact)\n' "$def_bytes"
  PASS=$((PASS + 1))
else
  printf '  FAIL: default payload too large (%s bytes)\n' "$def_bytes"
  FAIL=$((FAIL + 1))
fi

echo "=== single view: --full inlines the artifact ==="
full_out="$(ccs-jobs d-slim --full 2>/dev/null)"
assert_contains "--full inlines the full output" "$full_out" "xxxxxxxxxx"

echo "=== handoff frontmatter summary parser ==="
hf="$DD/results/hf-sample.handoff"
printf -- '---\nsummary:   clean intended line   \noutcome: done\n---\n\nsummary: body decoy\n' > "$hf"
assert_eq "parser extracts + trims frontmatter summary" \
  "clean intended line" "$(_ccs_dispatch_parse_handoff_summary "$hf")"
printf '# no frontmatter\nsummary: body\n' > "$hf"
assert_eq "parser returns empty when no frontmatter" \
  "" "$(_ccs_dispatch_parse_handoff_summary "$hf")"
# Unterminated frontmatter must NOT leak a body summary (review finding #3).
printf -- '---\noutcome: done\nsummary: leaked from unterminated block\n' > "$hf"
assert_eq "parser ignores summary in unterminated frontmatter" \
  "" "$(_ccs_dispatch_parse_handoff_summary "$hf")"
# CRLF line endings tolerated (review finding #2).
printf -- '---\r\nsummary: crlf line\r\n---\r\n' > "$hf"
assert_eq "parser tolerates CRLF frontmatter" \
  "crlf line" "$(_ccs_dispatch_parse_handoff_summary "$hf")"
# Colon-in-value preserved.
printf -- '---\nsummary: fix: the bar\n---\n' > "$hf"
assert_eq "parser preserves colons in the value" \
  "fix: the bar" "$(_ccs_dispatch_parse_handoff_summary "$hf")"

echo "=== ccs-jobs: --full accepted before the id (review finding #4) ==="
reset_jobs
jrec '{"job_id":"d-pos","project":"p","backend":"headless","status":"completed","summary":"pos test","created_at":"2026-07-03T10:00:00+08:00"}'
{ printf '## Output\n'; head -c 3000 /dev/zero | tr '\0' 'y'; } > "$DD/results/d-pos.md"
assert_contains "--full before id still inlines output" \
  "$(ccs-jobs --full d-pos 2>/dev/null)" "yyyyyyyyyy"

test_summary
