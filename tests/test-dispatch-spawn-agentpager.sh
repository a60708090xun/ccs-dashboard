#!/usr/bin/env bash
# tests/test-dispatch-spawn-agentpager.sh — agent-pager spawn backend (stage 2)
# Unit coverage for the spawn helpers. The live monitor loop (tmux + real
# worker) is covered by E2E, not here; spawn tests set
# CCS_DISPATCH_AGENTPAGER_MONITOR=0 to skip starting the background monitor.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Sandbox the data dir BEFORE sourcing anything that resolves it, so the test's
# d-test-* records never land in the user's real jobs.jsonl (mirrors the
# sibling test-jobs-agentpager.sh isolation).
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-spawn-ap-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

RS=$'\x1e'; US=$'\x1f'

echo "=== worker prompt carries handoff-gating invariant ==="
p="$(_ccs_dispatch_agentpager_prompt "d-test-1234" $'VERIFICATION RULE ...\nTask: do X')"
assert_contains "prompt keeps original task" "$p" "Task: do X"
assert_contains "prompt names per-job handoff file" "$p" "tmp/handoff-d-test-1234.md"
assert_contains "prompt references the job id" "$p" "d-test-1234"
assert_contains "prompt carries the autonomy invariant" "$p" "Do not ask clarifying questions"
assert_contains "prompt routes blocked to outcome: blocked" "$p" "outcome: blocked"

echo "=== launch file has valid frontmatter + body ==="
tmproot="$SCRIPT_DIR/tmp/test-spawn-ap-pager"
rm -rf "$tmproot"; mkdir -p "$tmproot"
lf="$(_ccs_dispatch_agentpager_launch_file "d-test-1234" "ccs-dashboard" "local-tester" "hello worker body" "$tmproot")"
assert_eq "launch file created" "yes" "$([ -f "$lf" ] && echo yes)"
# parse the same way inbound-handler.sh does (parse_field + get_body)
kind=$(sed -n 's/^kind: //p' "$lf" | head -1)
slot=$(sed -n 's/^slot: //p' "$lf" | head -1)
projk=$(sed -n 's/^proj: //p' "$lf" | head -1)
body=$(awk 'f>=2{print; next} /^---$/{f++}' "$lf")
assert_eq "kind is launch" "launch" "$kind"
assert_eq "slot is the local key" "local-tester" "$slot"
assert_eq "proj is the resolved key" "ccs-dashboard" "$projk"
assert_contains "body carries the worker prompt" "$body" "hello worker body"
assert_eq "cli defaults to claude" "claude" "$(sed -n 's/^cli: //p' "$lf" | head -1)"

echo "=== launch file honors cli selector (gemini) ==="
lfg="$(_ccs_dispatch_agentpager_launch_file "d-test-gem" "ccs-dashboard" "local-tester" "gem worker body" "$tmproot" gemini)"
assert_eq "cli is gemini when selected" "gemini" "$(sed -n 's/^cli: //p' "$lfg" | head -1)"
assert_eq "gemini launch kind still launch" "launch" "$(sed -n 's/^kind: //p' "$lfg" | head -1)"
assert_eq "no model line when the task declares none" "" \
  "$(sed -n 's/^model: //p' "$lfg" | head -1)"

echo "=== launch file carries the declared model ==="
# the launcher resolves this alias against its own registry, so the field must
# arrive verbatim; omitting it left the worker on whatever default its CLI saved
lfm="$(_ccs_dispatch_agentpager_launch_file "d-test-mdl" "ccs-dashboard" "local-tester" "mdl worker body" "$tmproot" gemini "gemini-3.5-flash")"
assert_eq "model is written when declared" "gemini-3.5-flash" \
  "$(sed -n 's/^model: //p' "$lfm" | head -1)"
assert_eq "model does not disturb cli" "gemini" "$(sed -n 's/^cli: //p' "$lfm" | head -1)"
assert_contains "model does not disturb the body" "$(sed -n '/^---$/,$p' "$lfm" | sed -n '/^---$/,$p')" "mdl worker body"

echo "=== stop file targets the local key ==="
sf="$(_ccs_dispatch_agentpager_stop_file "local-tester" "$tmproot")"
assert_eq "stop kind" "stop" "$(sed -n 's/^kind: //p' "$sf" | head -1)"
assert_eq "stop slot" "local-tester" "$(sed -n 's/^slot: //p' "$sf" | head -1)"
rm -rf "$tmproot"

echo "=== collect emits only this job's frames (byte offset) ==="
strm="$SCRIPT_DIR/tmp/test-spawn-ap.stream"
# a previous job's frame already in the per-user stream (append-only, persists)
printf '%sMSG%sprev%s\nOLD BODY\n%sEND%s\n' "$RS" "$US" "$RS" "$RS" "$RS" > "$strm"
off=$(stat -c %s "$strm")
# this job's frames appended after the launch offset
printf '%sMSG%stool%s\nran build\n%sEND%s\n' "$RS" "$US" "$RS" "$RS" "$RS" >> "$strm"
printf '%sMSG%sprose%s\ndone task\n%sEND%s\n' "$RS" "$US" "$RS" "$RS" "$RS" >> "$strm"
dest="$SCRIPT_DIR/tmp/test-spawn-ap.raw"
_ccs_dispatch_agentpager_collect "$strm" "$off" "$dest"
got="$(cat "$dest")"
assert_contains "collect has this-job frame 1" "$got" "ran build"
assert_contains "collect has this-job frame 2" "$got" "done task"
assert_not_contains "collect excludes previous job's frame" "$got" "OLD BODY"
rm -f "$strm" "$dest"

echo "=== finish with handoff -> handoff-ready ==="
dd="$(_ccs_dispatch_dir)"
jid="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$jid" --arg p "myproj" \
  --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:$p,backend:"agentpager",created_at:$ca,status:"running"}')"
printf 'raw output line\n' > "$dd/results/${jid}.raw"
hf="$SCRIPT_DIR/tmp/handoff-${jid}.md"
printf '# handoff\nstuff\n' > "$hf"
_ccs_dispatch_finish_agentpager "$jid" "$hf"
st=$(_ccs_dispatch_jsonl_latest "$jid" | jq -r '.status')
assert_eq "status is handoff-ready" "handoff-ready" "$st"
assert_eq "handoff captured to results" "yes" "$([ -f "$dd/results/${jid}.handoff" ] && echo yes)"
assert_contains ".md carries the raw output" "$(cat "$dd/results/${jid}.md")" "raw output line"
rm -f "$hf" "$dd/results/${jid}".*

echo "=== finish without handoff -> completed ==="
jid2="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$jid2" --arg p "myproj" \
  --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:$p,backend:"agentpager",created_at:$ca,status:"running"}')"
printf 'some output\n' > "$dd/results/${jid2}.raw"
_ccs_dispatch_finish_agentpager "$jid2" "$SCRIPT_DIR/tmp/nonexistent-handoff.md"
st2=$(_ccs_dispatch_jsonl_latest "$jid2" | jq -r '.status')
assert_eq "status is completed (no handoff)" "completed" "$st2"
assert_eq "no stray handoff file" "no" "$([ -f "$dd/results/${jid2}.handoff" ] && echo yes || echo no)"
rm -f "$dd/results/${jid2}".*

echo "=== spawn is async-only: --sync falls back (rc 2) ==="
rc=0
_ccs_dispatch_spawn_agentpager "d-sync" "$SCRIPT_DIR" "prompt" 60 sync >/dev/null 2>&1 || rc=$?
assert_eq "sync -> rc 2 (fall back to headless)" "2" "$rc"

echo "=== spawn falls back when proj-map cannot resolve (rc 2) ==="
rc=0
CCS_DISPATCH_PROJ_MAP="$SCRIPT_DIR/tmp/nonexistent-projmap" \
  _ccs_dispatch_spawn_agentpager "d-noproj" "$SCRIPT_DIR" "prompt" 60 async \
  >/dev/null 2>&1 || rc=$?
assert_eq "no proj-map -> rc 2 (fall back to headless)" "2" "$rc"

echo "=== spawn (async) writes launch inbound when proj resolves ==="
_ccs_dispatch_agentpager_session_alive() { return 1; }  # no live seat -> guard passes
projdir="$SCRIPT_DIR/tmp/test-spawn-ap-proj"; mkdir -p "$projdir"
pmap="$SCRIPT_DIR/tmp/test-spawn-ap-projmap"
printf 'ccs-dashboard = %s\n' "$projdir" > "$pmap"
pager="$SCRIPT_DIR/tmp/test-spawn-ap-pager2"; mkdir -p "$pager/inbound"
rc=0
CCS_DISPATCH_PROJ_MAP="$pmap" AGENT_PAGER_DIR="$pager" \
  CCS_DISPATCH_AGENTPAGER_MONITOR=0 \
  _ccs_dispatch_spawn_agentpager "d-ok" "$projdir" "the prompt body" 60 async \
  >/dev/null 2>&1 || rc=$?
assert_eq "async spawn returns 0" "0" "$rc"
found=$(ls "$pager/inbound/"*-d-ok.md 2>/dev/null | head -1)
assert_eq "launch inbound written" "yes" "$([ -n "$found" ] && echo yes)"
assert_contains "inbound is a launch" "$(cat "$found" 2>/dev/null)" "kind: launch"
assert_contains "inbound carries the worker prompt" "$(cat "$found" 2>/dev/null)" "the prompt body"
assert_contains "inbound carries handoff-gating invariant" "$(cat "$found" 2>/dev/null)" "tmp/handoff-d-ok.md"
rm -rf "$projdir" "$pmap" "$pager"

echo "=== spawn (async) threads cli=gemini into the launch inbound ==="
_ccs_dispatch_agentpager_session_alive() { return 1; }  # no live seat -> guard passes
gprojdir="$SCRIPT_DIR/tmp/test-spawn-ap-gem-proj"; mkdir -p "$gprojdir"
gpmap="$SCRIPT_DIR/tmp/test-spawn-ap-gem-map"
printf 'ccs-dashboard = %s\n' "$gprojdir" > "$gpmap"
gpager="$SCRIPT_DIR/tmp/test-spawn-ap-gem-pager"; mkdir -p "$gpager/inbound"
CCS_DISPATCH_PROJ_MAP="$gpmap" AGENT_PAGER_DIR="$gpager" CCS_DISPATCH_AGENTPAGER_MONITOR=0 \
  _ccs_dispatch_spawn_agentpager "d-gem-ok" "$gprojdir" "gem prompt body" 60 async 0 5 gemini \
  >/dev/null 2>&1
gfound=$(ls "$gpager/inbound/"*-d-gem-ok.md 2>/dev/null | head -1)
assert_eq "gemini spawn wrote an inbound" "yes" "$([ -n "$gfound" ] && echo yes)"
assert_contains "spawned inbound selects gemini" "$(cat "$gfound" 2>/dev/null)" "cli: gemini"
rm -rf "$gprojdir" "$gpmap" "$gpager"

echo "=== last-activity reflects the out.stream mtime ==="
la_root="$SCRIPT_DIR/tmp/test-spawn-ap-la"
mkdir -p "$la_root/channels/local-tester"
printf 'x' > "$la_root/channels/local-tester/out.stream"
la="$(_ccs_dispatch_agentpager_last_activity "local-tester" "$la_root")"
assert_contains "last-activity is an ISO timestamp" "$la" "$(date +%Y)"
la2="$(_ccs_dispatch_agentpager_last_activity "local-nostream" "$la_root")"
assert_eq "no stream -> empty last-activity" "" "$la2"
rm -rf "$la_root"

echo "=== ccs-jobs single view shows last-activity for a running agentpager job ==="
dd="$(_ccs_dispatch_dir)"
jid3="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$jid3" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
# agentpager liveness = the worker's tmux session (not the monitor pid), so keep
# the session alive; sync_status then leaves the job running and the single view
# renders last-activity.
_ccs_dispatch_agentpager_session_alive() { return 0; }
apdir="$SCRIPT_DIR/tmp/test-spawn-ap-jobs"
mkdir -p "$apdir/channels/local-$(id -un)"
printf 'frame' > "$apdir/channels/local-$(id -un)/out.stream"
out="$(AGENT_PAGER_DIR="$apdir" ccs-jobs "$jid3" 2>/dev/null)"
assert_contains "single view shows Last activity" "$out" "Last activity:"
rm -rf "$apdir"; rm -f "$dd/pids/${jid3}.pid" "$dd/results/${jid3}".*

echo "=== monitor tolerates worker-startup lag, then finalizes handoff-ready ==="
# Regression: the runner spawns the tmux worker a few seconds AFTER ccs writes
# the launch, so has-session is false when the monitor starts. The monitor must
# WAIT for the session to appear, not conclude "already gone" and finalize early.
dd="$(_ccs_dispatch_dir)"
mjid="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$mjid" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
mroot="$SCRIPT_DIR/tmp/test-spawn-ap-monitor"
rm -rf "$mroot"; mkdir -p "$mroot/channels/local-tester" "$mroot/proj/tmp"
export _MON_CNT="$mroot/salive.count"; echo 0 > "$_MON_CNT"
export _MON_STREAM="$mroot/channels/local-tester/out.stream"
export _MON_HANDOFF="$mroot/proj/tmp/handoff-${mjid}.md"
# mock: session is NOT up for the first 2 checks (startup lag); on the 3rd check
# it comes up and the worker emits a frame + writes its handoff; then it ends.
_ccs_dispatch_agentpager_session_alive() {
  local n; n=$(( $(cat "$_MON_CNT") + 1 )); echo "$n" > "$_MON_CNT"
  if [ "$n" -eq 3 ]; then
    printf '%sMSG%stool%s\nworker did work\n%sEND%s\n' \
      "$RS" "$US" "$RS" "$RS" "$RS" > "$_MON_STREAM"
    printf '# handoff\n' > "$_MON_HANDOFF"
  fi
  [ "$n" -le 2 ] && return 1
  [ "$n" -le 4 ] && return 0
  return 1
}
# stub stop so the test never writes to a real inbound
_ccs_dispatch_agentpager_stop_file() { :; }
CCS_DISPATCH_AGENTPAGER_STARTUP=10 CCS_DISPATCH_AGENTPAGER_POLL=1 \
  CCS_DISPATCH_AGENTPAGER_SETTLE=1 CCS_DISPATCH_AGENTPAGER_SETTLE_QUIET=1 \
  _ccs_dispatch_agentpager_monitor "$mjid" "local-tester" "$mroot/proj" 0 "$mroot"
mst=$(_ccs_dispatch_jsonl_latest "$mjid" | jq -r '.status')
assert_eq "monitor finalized handoff-ready (not premature completed)" "handoff-ready" "$mst"
assert_contains "monitor collected the worker's frame, not just the banner" \
  "$(cat "$dd/results/${mjid}.md" 2>/dev/null)" "worker did work"
unset _MON_CNT _MON_STREAM _MON_HANDOFF
rm -rf "$mroot"; rm -f "$dd/results/${mjid}".*

echo "=== spawn refuses when a local worker is already running (rc 2) ==="
_ccs_dispatch_agentpager_session_alive() { return 0; }  # simulate a live seat
gpd="$SCRIPT_DIR/tmp/test-spawn-ap-guard-proj"; mkdir -p "$gpd"
gpm="$SCRIPT_DIR/tmp/test-spawn-ap-guard-map"; printf 'ccs-dashboard = %s\n' "$gpd" > "$gpm"
gpg="$SCRIPT_DIR/tmp/test-spawn-ap-guard-pager"; mkdir -p "$gpg/inbound"
rc=0
CCS_DISPATCH_PROJ_MAP="$gpm" AGENT_PAGER_DIR="$gpg" CCS_DISPATCH_AGENTPAGER_MONITOR=0 \
  _ccs_dispatch_spawn_agentpager "d-guard" "$gpd" "p" 60 async >/dev/null 2>&1 || rc=$?
assert_eq "already-running local seat -> rc 2 (fall back)" "2" "$rc"
assert_eq "no launch written when refused" "no" \
  "$([ -n "$(ls "$gpg/inbound/"*-d-guard.md 2>/dev/null)" ] && echo yes || echo no)"
rm -rf "$gpd" "$gpm" "$gpg"

echo "=== finish: never-observed launch -> failed (not completed) ==="
fjid="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$fjid" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
printf 'x\n' > "$dd/results/${fjid}.raw"
_ccs_dispatch_finish_agentpager "$fjid" "$SCRIPT_DIR/tmp/nope-handoff.md" "failed"
assert_eq "no handoff + failed floor -> failed" "failed" \
  "$(_ccs_dispatch_jsonl_latest "$fjid" | jq -r '.status')"
rm -f "$dd/results/${fjid}".*

echo "=== finish: whitespace-only raw -> (no output) ==="
zjid="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$zjid" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
printf '\n' > "$dd/results/${zjid}.raw"   # lone newline = zero-frame collect output
zhf="$SCRIPT_DIR/tmp/handoff-${zjid}.md"; printf '# h\n' > "$zhf"
_ccs_dispatch_finish_agentpager "$zjid" "$zhf"
assert_contains "blank raw renders (no output)" \
  "$(cat "$dd/results/${zjid}.md")" "(no output)"
rm -f "$zhf" "$dd/results/${zjid}".*

echo "=== ccs-jobs list shows full handoff-ready status (not truncated) ==="
hjid="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$hjid" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$hjid" --arg fa "$(date -Iseconds)" \
  '{job_id:$jid,status:"handoff-ready",finished_at:$fa,handoff:true}')"
assert_contains "list shows full handoff-ready" "$(ccs-jobs 2>/dev/null)" "handoff-ready"

echo "=== monitor resolves handoff path from agent-pager state cwd (no drift) ==="
f3jid="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$f3jid" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
f3="$SCRIPT_DIR/tmp/test-spawn-ap-mon3"
rm -rf "$f3"; mkdir -p "$f3/channels/local-tester" "$f3/state/sessions" \
  "$f3/realcwd/tmp" "$f3/wrongcwd/tmp"
printf '{"key":"local-tester","cwd":"%s","channel":"local"}\n' "$f3/realcwd" \
  > "$f3/state/sessions/local-tester.json"
printf '# h\n' > "$f3/realcwd/tmp/handoff-${f3jid}.md"   # handoff in the REAL cwd
printf '%sMSG%st%s\ndid work\n%sEND%s\n' "$RS" "$US" "$RS" "$RS" "$RS" \
  > "$f3/channels/local-tester/out.stream"
export _M3="$f3/cnt"; echo 0 > "$_M3"
_ccs_dispatch_agentpager_session_alive() {
  local n; n=$(( $(cat "$_M3") + 1 )); echo "$n" > "$_M3"; [ "$n" -le 1 ]; }
_ccs_dispatch_agentpager_stop_file() { :; }
CCS_DISPATCH_AGENTPAGER_STARTUP=5 CCS_DISPATCH_AGENTPAGER_POLL=1 \
  CCS_DISPATCH_AGENTPAGER_STOP_WAIT=1 \
  CCS_DISPATCH_AGENTPAGER_SETTLE=1 CCS_DISPATCH_AGENTPAGER_SETTLE_QUIET=1 \
  _ccs_dispatch_agentpager_monitor "$f3jid" "local-tester" "$f3/wrongcwd" 0 "$f3"
assert_eq "handoff found via state cwd -> handoff-ready" "handoff-ready" \
  "$(_ccs_dispatch_jsonl_latest "$f3jid" | jq -r '.status')"
unset _M3; rm -rf "$f3"; rm -f "$dd/results/${f3jid}".*

echo "=== monitor: session never appears -> failed ==="
gjid="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$gjid" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
groot="$SCRIPT_DIR/tmp/test-spawn-ap-mon1"; rm -rf "$groot"; mkdir -p "$groot/channels/local-tester"
_ccs_dispatch_agentpager_session_alive() { return 1; }  # never comes up
CCS_DISPATCH_AGENTPAGER_STARTUP=2 CCS_DISPATCH_AGENTPAGER_POLL=1 \
  _ccs_dispatch_agentpager_monitor "$gjid" "local-tester" "$groot" 0 "$groot"
assert_eq "never-observed session -> failed" "failed" \
  "$(_ccs_dispatch_jsonl_latest "$gjid" | jq -r '.status')"
rm -rf "$groot"; rm -f "$dd/results/${gjid}".*

echo "=== monitor: stop unhonored -> retries + handoff-ready + note ==="
hjid2="d-test-$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$hjid2" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"p",backend:"agentpager",created_at:$ca,status:"running"}')"
hroot="$SCRIPT_DIR/tmp/test-spawn-ap-mon2"; rm -rf "$hroot"
mkdir -p "$hroot/channels/local-tester" "$hroot/proj/tmp"
printf '# h\n' > "$hroot/proj/tmp/handoff-${hjid2}.md"
printf '%sMSG%st%s\nwork\n%sEND%s\n' "$RS" "$US" "$RS" "$RS" "$RS" \
  > "$hroot/channels/local-tester/out.stream"
_ccs_dispatch_agentpager_session_alive() { return 0; }  # never stops
export _HSTOP="$hroot/stopcnt"; echo 0 > "$_HSTOP"
_ccs_dispatch_agentpager_stop_file() { echo $(( $(cat "$_HSTOP") + 1 )) > "$_HSTOP"; }
CCS_DISPATCH_AGENTPAGER_STARTUP=2 CCS_DISPATCH_AGENTPAGER_POLL=1 \
  CCS_DISPATCH_AGENTPAGER_STOP_WAIT=1 \
  CCS_DISPATCH_AGENTPAGER_SETTLE=1 CCS_DISPATCH_AGENTPAGER_SETTLE_QUIET=1 \
  _ccs_dispatch_agentpager_monitor "$hjid2" "local-tester" "$hroot/proj" 0 "$hroot"
assert_eq "handoff captured despite failed stop -> handoff-ready" "handoff-ready" \
  "$(_ccs_dispatch_jsonl_latest "$hjid2" | jq -r '.status')"
assert_eq "stop re-sent (>=2 attempts)" "yes" \
  "$([ "$(cat "$_HSTOP")" -ge 2 ] && echo yes || echo no)"
assert_contains "note records the unstopped worker" \
  "$(cat "$dd/results/${hjid2}.md")" "did not stop"
unset _HSTOP; rm -rf "$hroot"; rm -f "$dd/results/${hjid2}".*

test_summary
