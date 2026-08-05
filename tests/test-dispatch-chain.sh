#!/usr/bin/env bash
# tests/test-dispatch-chain.sh — chained-handoffs auto-chain (Task 11).
# Units: generic frontmatter field parser, autonomy invariant, context bridge,
# continuation predicate, chain_next lineage + recursion (monitor mock).
# Isolation: XDG_DATA_HOME sandbox + AGENT_PAGER_DIR sandbox; tmux mocked via
# overriding _ccs_dispatch_agentpager_session_alive.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-chain-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

RS=$'\x1e'; US=$'\x1f'
DD="$(_ccs_dispatch_dir)"
JOBS="$DD/jobs.jsonl"

reset_jobs() {
  rm -f "$JOBS"; rm -rf "$DD/results" "$DD/pids"
  mkdir -p "$DD/results" "$DD/pids"
}

echo "=== generic field parser: outcome + next from closed frontmatter ==="
ff="$DD/parse-sample.handoff"
mkdir -p "$DD"
printf -- '---\nsummary: did the thing\noutcome:  done \nnext: wire up the API\n---\n\noutcome: body decoy\n' > "$ff"
assert_eq "field parser reads outcome (trimmed)" \
  "done" "$(_ccs_dispatch_parse_handoff_field "$ff" outcome)"
assert_eq "field parser reads next" \
  "wire up the API" "$(_ccs_dispatch_parse_handoff_field "$ff" next)"
assert_eq "field parser reads summary" \
  "did the thing" "$(_ccs_dispatch_parse_handoff_field "$ff" summary)"
assert_eq "missing field -> empty" \
  "" "$(_ccs_dispatch_parse_handoff_field "$ff" nonesuch)"
# Unterminated frontmatter must not leak a body field.
printf -- '---\noutcome: done\nnext: leaked\n' > "$ff"
assert_eq "unterminated frontmatter -> empty next" \
  "" "$(_ccs_dispatch_parse_handoff_field "$ff" next)"
# Summary delegate keeps its public behavior (regression).
printf -- '---\nsummary: fix: the bar\n---\n' > "$ff"
assert_eq "summary delegate preserves colons" \
  "fix: the bar" "$(_ccs_dispatch_parse_handoff_summary "$ff")"

echo "=== autonomy invariant present in every agentpager worker prompt ==="
ap="$(_ccs_dispatch_agentpager_prompt "d-auto-1" $'Task: do X')"
assert_contains "prompt keeps the task" "$ap" "Task: do X"
assert_contains "prompt still names the per-job handoff" "$ap" "tmp/handoff-d-auto-1.md"
assert_contains "prompt forbids clarifying questions" "$ap" "Do not ask clarifying questions"
assert_contains "prompt routes blocked to outcome: blocked" "$ap" "outcome: blocked"
# The dictated frontmatter carries the schema marker, so a worker following the
# prompt emits the same shape as the structured-handoff contract (issue 112 #4).
assert_contains "prompt dictates the handoff/v1 schema marker" "$ap" "handoff_schema: handoff/v1"
# ccs-handoff emits no frontmatter and lands elsewhere; the prompt must scope it
# to the prose rather than recommend it for the whole file (issue 112 #3).
assert_contains "prompt scopes ccs-handoff to the prose" "$ap" "draft the PROSE"
# Flatten first: the pre-fix prompt wrapped this phrase across two lines, so a
# line-based grep never matched it and the guard passed even on the old text.
if printf '%s' "$ap" | tr '\n' ' ' | grep -q "use ccs-handoff for the content if helpful"; then
  printf '  FAIL: prompt still recommends ccs-handoff for the whole file\n'; FAIL=$((FAIL + 1))
else
  printf '  PASS: prompt no longer recommends ccs-handoff for the whole file\n'; PASS=$((PASS + 1))
fi

echo "=== context bridge carries parent summary + body, capped ==="
# Pin both knobs this section depends on. An inherited cap moves every boundary
# asserted below; and under LC_ALL=C bash's ${#var} counts bytes too, which
# would silently drain the CJK case at the end of the section of its whole
# point (it exists to tell the two ways of measuring apart).
CHAIN_BRIDGE_CAP_SAVED="${CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS:-}"
LC_ALL_SAVED="${LC_ALL:-}"
CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS=4000
export LC_ALL=C.UTF-8
bh="$DD/bridge.handoff"
printf -- '---\nsummary: added the parser\noutcome: done\nnext: add the writer\n---\n\nI added parse_field() in ccs-dispatch.sh.\nKey decision: delegate summary to it.\n' > "$bh"
br="$(_ccs_dispatch_chain_context_bridge "$bh")"
assert_contains "bridge includes the parent summary" "$br" "added the parser"
assert_contains "bridge includes the parent body highlight" "$br" "Key decision: delegate"
assert_contains "bridge frames it as a continuation" "$br" "previous worker"
# An intact body must NOT be flagged -- without this the marker assertion below
# would pass on a function that marks unconditionally.
if printf '%s' "$br" | grep -q "context truncated"; then
  printf '  FAIL: short body wrongly flagged as truncated\n'; FAIL=$((FAIL + 1))
else
  printf '  PASS: short body carries no truncation marker\n'; PASS=$((PASS + 1))
fi
# Absent file -> empty bridge.
assert_eq "absent handoff -> empty bridge" "" "$(_ccs_dispatch_chain_context_bridge "$DD/nope.handoff")"
# Cap enforced.
{ printf -- '---\nsummary: big\n---\n'; head -c 9000 /dev/zero | tr '\0' 'Z'; } > "$bh"
brb=$(_ccs_dispatch_chain_context_bridge "$bh" | wc -c)
if [ "$brb" -le 5000 ]; then
  printf '  PASS: bridge capped (%s bytes)\n' "$brb"; PASS=$((PASS + 1))
else
  printf '  FAIL: bridge not capped (%s bytes)\n' "$brb"; FAIL=$((FAIL + 1))
fi
# A cut body says so, names the cap, and points at the full file: the next hop
# would otherwise read a sliced handoff as a complete one (issue 112 #2).
brt="$(_ccs_dispatch_chain_context_bridge "$bh")"
assert_contains "truncated bridge says it was truncated" "$brt" "context truncated"
assert_contains "truncated bridge names the cap" "$brt" "at $CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS of 9000 bytes"
assert_contains "truncated bridge points at the parent handoff" "$brt" "$bh"
# CJK body ~7000 bytes but only ~2500 characters: head -c cuts it, so the marker
# is required. A ${#var} check counts characters, stays under the cap, and would
# silently ship a sliced body as if it were whole -- this is the discriminating
# case between the two ways of measuring.
{ printf -- '---\nsummary: cjk\n---\n'
  for _ in $(seq 1 250); do printf '交接內容中文十個字\n'; done; } > "$bh"
brc="$(_ccs_dispatch_chain_context_bridge "$bh")"
if printf '%s' "$brc" | grep -q "context truncated"; then
  printf '  PASS: CJK body measured in bytes, not characters\n'; PASS=$((PASS + 1))
else
  printf '  FAIL: CJK body over the byte cap not flagged (character-based check?)\n'; FAIL=$((FAIL + 1))
fi
# A cap the shell cannot compare would otherwise drop the body whole, silently.
CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS=notanumber
brn="$(_ccs_dispatch_chain_context_bridge "$bh" 2>/dev/null)"
assert_contains "non-numeric cap falls back to the default" "$brn" "at 4000 of"
CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS=4000
# Restore what this section pinned, so later sections see the caller's values.
[ -n "$CHAIN_BRIDGE_CAP_SAVED" ] \
  && CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS="$CHAIN_BRIDGE_CAP_SAVED"
if [ -n "$LC_ALL_SAVED" ]; then export LC_ALL="$LC_ALL_SAVED"; else unset LC_ALL; fi

echo "=== continuation predicate: all branches ==="
csr() { _ccs_dispatch_chain_stop_reason "$@"; }
assert_eq "done + next + depth<max -> continue (empty)" \
  "" "$(csr handoff-ready done 'do next' 0 5)"
assert_eq "outcome partial -> partial" \
  "partial" "$(csr handoff-ready partial 'do next' 0 5)"
assert_eq "outcome blocked -> blocked" \
  "blocked" "$(csr handoff-ready blocked 'do next' 0 5)"
assert_eq "status failed (no handoff) -> failed" \
  "failed" "$(csr failed '' '' 0 5)"
assert_eq "status completed w/o handoff outcome -> failed" \
  "failed" "$(csr completed '' '' 0 5)"
assert_eq "done + empty next -> empty-next" \
  "empty-next" "$(csr handoff-ready done '' 0 5)"
assert_eq "done + next but depth == max -> depth" \
  "depth" "$(csr handoff-ready done 'do next' 5 5)"
assert_eq "done + next + last allowed depth (max-1) -> continue" \
  "" "$(csr handoff-ready done 'do next' 4 5)"

echo "=== chain engine: hop1 done+next -> hop2 launched; hop2 partial -> stop ==="
reset_jobs
export AGENT_PAGER_DIR="$SCRIPT_DIR/tmp/test-chain-pager"
rm -rf "$AGENT_PAGER_DIR"
mkdir -p "$AGENT_PAGER_DIR/channels/local-tester" "$AGENT_PAGER_DIR/inbound"
CROOT="$SCRIPT_DIR/tmp/test-chain-proj"; rm -rf "$CROOT"; mkdir -p "$CROOT/tmp"
CPMAP="$SCRIPT_DIR/tmp/test-chain-projmap"
printf 'ccs-dashboard = %s\n' "$CROOT" > "$CPMAP"
export CCS_DISPATCH_PROJ_MAP="$CPMAP"
# Disable notify sender resolution (no agent-pager unit in tests).
export CCS_DISPATCH_NOTIFY=0

HEAD="d-chain-head"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$HEAD" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"ccs-dashboard",backend:"agentpager",created_at:$ca,
    status:"running",chain:true,chain_depth:0,chain_max:5}')"
echo $$ > "$DD/pids/${HEAD}.pid"

export _CHAIN_CROOT="$CROOT"
# Report the worker session gone on every check: the hop's handoff already
# exists, so the monitor's Phase B loop exits at once and finalizes.
_ccs_dispatch_agentpager_session_alive() { return 1; }
_ccs_dispatch_agentpager_stop_file() { :; }

# HEAD handoff (done + next) pre-seeded in the project tmp.
printf -- '---\nsummary: head done\noutcome: done\nnext: do the second step\n---\nhead body\n' \
  > "$CROOT/tmp/handoff-${HEAD}.md"

# Intercept launch-file writes to learn the next hop's job id, capture the
# prompt, and seed ITS handoff as partial (so hop 2 stops the chain).
_ccs_dispatch_agentpager_launch_file() {
  local job_id="$1" proj="$2" key="$3" prompt="$4" pager_dir="$5"
  printf '%s\n' "$prompt" > "$_CHAIN_CROOT/last-launch.txt"
  printf '%s\n' "$job_id" >> "$_CHAIN_CROOT/launched-ids.txt"
  printf -- '---\nsummary: second partial\noutcome: partial\nnext: more\n---\nbody2\n' \
    > "$_CHAIN_CROOT/tmp/handoff-${job_id}.md"
  printf '%s/inbound/stub-%s.md\n' "$pager_dir" "$job_id"
}

CCS_DISPATCH_AGENTPAGER_STARTUP=1 CCS_DISPATCH_AGENTPAGER_POLL=1 \
  CCS_DISPATCH_AGENTPAGER_SETTLE=1 CCS_DISPATCH_AGENTPAGER_SETTLE_QUIET=1 \
  _ccs_dispatch_agentpager_monitor "$HEAD" "local-tester" "$CROOT" 0 "$AGENT_PAGER_DIR" \
    1 0 5 ""

assert_eq "head finalized handoff-ready" "handoff-ready" \
  "$(_ccs_dispatch_jsonl_latest "$HEAD" | jq -r '.status')"
HOP2=$(head -1 "$CROOT/launched-ids.txt")
assert_eq "exactly one hop launched" "1" "$(wc -l < "$CROOT/launched-ids.txt" | tr -d ' ')"
assert_contains "hop2 launch carries the next task" \
  "$(cat "$CROOT/last-launch.txt")" "do the second step"
assert_contains "hop2 launch carries the parent context bridge" \
  "$(cat "$CROOT/last-launch.txt")" "previous worker"
assert_contains "hop2 launch carries the HANDOFF RULE" \
  "$(cat "$CROOT/last-launch.txt")" "tmp/handoff-${HOP2}.md"
assert_eq "hop2 chain_parent is the head" "$HEAD" \
  "$(_ccs_dispatch_jsonl_latest "$HOP2" | jq -r '.chain_parent')"
assert_eq "hop2 chain_depth is 1" "1" \
  "$(_ccs_dispatch_jsonl_latest "$HOP2" | jq -r '.chain_depth')"
assert_eq "hop2 chain_stopped is partial" "partial" \
  "$(_ccs_dispatch_jsonl_latest "$HOP2" | jq -r '.chain_stopped')"

unset _CHAIN_CROOT AGENT_PAGER_DIR CCS_DISPATCH_PROJ_MAP CCS_DISPATCH_NOTIFY
rm -rf "$CROOT" "$CPMAP" "$SCRIPT_DIR/tmp/test-chain-pager"

echo "=== --chain preview names chain mode + depth (agentpager) ==="
pv="$(_ccs_dispatch_preview_render "/p" "agentpager" "async" "600" "Task: x" 1 5)"
assert_contains "preview shows chain mode" "$pv" "chain"
assert_contains "preview shows the max depth" "$pv" "5"
echo "=== preview without chain has no chain line (regression) ==="
pv0="$(_ccs_dispatch_preview_render "/p" "agentpager" "async" "600" "Task: x")"
assert_not_contains "no chain line when not chained" "$pv0" "auto-continue"

echo "=== --chain on headless warns and dispatches a single job (no chain flag) ==="
reset_jobs
export CCS_DISPATCH_BACKEND=headless
# Mock claude on PATH so the headless spawn never launches the real binary.
mock_bin="$SCRIPT_DIR/tmp/test-chain-bin"; mkdir -p "$mock_bin"
printf '#!/bin/bash\necho "mock: $*"\n' > "$mock_bin/claude"; chmod +x "$mock_bin/claude"
chp="$SCRIPT_DIR/tmp/test-chain-hl-proj"; mkdir -p "$chp"
warn="$(PATH="$mock_bin:$PATH" ccs-dispatch --sync --chain --project "$chp" --yes "do a thing" 2>&1 >/dev/null)"
assert_contains "headless --chain emits a warning" "$warn" "chain"
# The dispatched head job must NOT carry chain:true (headless can't chain).
hid=$(jq -rs 'map(.job_id)|last' "$JOBS")
assert_eq "headless head job is not chained" "null" \
  "$(_ccs_dispatch_jsonl_latest "$hid" | jq -r '.chain // "null"')"
rm -rf "$chp" "$mock_bin"; unset CCS_DISPATCH_BACKEND

echo "=== --max-depth rejects a non-integer (protects the runaway ceiling) ==="
reset_jobs
before_lines=$([ -f "$JOBS" ] && wc -l < "$JOBS" || echo 0)
mdproj="$SCRIPT_DIR/tmp/test-chain-md-proj"; mkdir -p "$mdproj"
rc=0
mderr="$(ccs-dispatch --chain --max-depth abc --project "$mdproj" --yes "x" 2>&1 >/dev/null)" || rc=$?
assert_eq "non-integer --max-depth aborts (rc 1)" "1" "$rc"
assert_contains "error names the bad flag" "$mderr" "max-depth"
after_lines=$([ -f "$JOBS" ] && wc -l < "$JOBS" || echo 0)
assert_eq "rejected dispatch appends no job record" "$before_lines" "$after_lines"
rm -rf "$mdproj"

echo "=== ccs-jobs single view prints chain lineage ==="
reset_jobs
jrec() { printf '%s\n' "$1" >> "$JOBS"; }
jrec '{"job_id":"d-hop","project":"p","backend":"agentpager","status":"handoff-ready","created_at":"2026-07-09T10:00:00+08:00","finished_at":"2026-07-09T10:05:00+08:00","chain":true,"chain_parent":"d-head","chain_depth":2,"chain_max":5}'
printf '# md\n' > "$DD/results/d-hop.md"
co="$(ccs-jobs d-hop 2>/dev/null)"
assert_contains "shows depth N/max" "$co" "depth 2/5"
assert_contains "shows the parent" "$co" "parent=d-head"

echo "=== ccs-jobs shows chain_stopped when present ==="
reset_jobs
jrec '{"job_id":"d-stp","project":"p","backend":"agentpager","status":"handoff-ready","created_at":"2026-07-09T10:00:00+08:00","chain":true,"chain_depth":1,"chain_max":5}'
jrec '{"job_id":"d-stp","chain_stopped":"blocked"}'
printf '# md\n' > "$DD/results/d-stp.md"
so="$(ccs-jobs d-stp 2>/dev/null)"
assert_contains "shows stop reason" "$so" "stopped: blocked"

echo "=== non-chain job has no Chain line (regression) ==="
reset_jobs
jrec '{"job_id":"d-plain","project":"p","backend":"headless","status":"completed","created_at":"2026-07-09T10:00:00+08:00"}'
printf '# md\n' > "$DD/results/d-plain.md"
po="$(ccs-jobs d-plain 2>/dev/null)"
assert_not_contains "no Chain line for a plain job" "$po" "**Chain:**"

echo "=== chain hop inherits the cli selector (AC4: gemini stays gemini) ==="
reset_jobs
acli_proj="$SCRIPT_DIR/tmp/test-chain-cli-proj"; mkdir -p "$acli_proj/tmp"
acli_map="$SCRIPT_DIR/tmp/test-chain-cli-map"
printf 'ccs-dashboard = %s\n' "$acli_proj" > "$acli_map"
acli_pager="$SCRIPT_DIR/tmp/test-chain-cli-pager"; mkdir -p "$acli_pager/inbound"
acli_cap="$SCRIPT_DIR/tmp/test-chain-cli.cap"; : > "$acli_cap"
PAR="d-chain-cli-head"
_ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$PAR" --arg ca "$(date -Iseconds)" \
  '{job_id:$jid,project:"ccs-dashboard",backend:"agentpager",created_at:$ca,
    status:"handoff-ready",chain:true,chain_depth:0,chain_max:5}')"
printf -- '---\noutcome: done\nnext: second step\n---\nbody\n' > "$DD/results/${PAR}.handoff"
# Capture the cli arg (slot 6) the hop's launch receives; no-op the monitor re-entry.
_ccs_dispatch_agentpager_launch_file() { printf '%s' "${6:-}" > "$acli_cap"; printf 'stub\n'; }
_ccs_dispatch_agentpager_monitor() { :; }
CCS_DISPATCH_PROJ_MAP="$acli_map" AGENT_PAGER_DIR="$acli_pager" CCS_DISPATCH_NOTIFY=0 \
  _ccs_dispatch_chain_next "$PAR" "local-tester" "$acli_proj" "$acli_pager" 0 5 gemini
assert_eq "hop launch inherits cli=gemini" "gemini" "$(cat "$acli_cap")"
hopid=$(jq -rs 'map(select(.chain_parent=="'"$PAR"'"))|last|.job_id' "$JOBS")
assert_eq "hop record records cli=gemini" "gemini" \
  "$(_ccs_dispatch_jsonl_latest "$hopid" | jq -r '.cli')"
rm -rf "$acli_proj" "$acli_map" "$acli_pager"; rm -f "$acli_cap"

echo "=== agentpager->headless runtime fallback records cli=claude (honesty) ==="
reset_jobs
export CCS_DISPATCH_BACKEND=agentpager
hbin="$SCRIPT_DIR/tmp/test-chain-honesty-bin"; mkdir -p "$hbin"
printf '#!/bin/bash\necho "mock: $*"\n' > "$hbin/claude"; chmod +x "$hbin/claude"
hproj="$SCRIPT_DIR/tmp/test-chain-honesty-proj"; mkdir -p "$hproj"
# --sync makes the agentpager backend return 2 -> real fallback to headless-claude.
PATH="$hbin:$PATH" ccs-dispatch --sync --cli gemini --project "$hproj" --yes "t" >/dev/null 2>&1
hid=$(jq -rs 'map(.job_id)|last' "$JOBS")
assert_eq "runtime fallback records cli=claude, not gemini" "claude" \
  "$(_ccs_dispatch_jsonl_latest "$hid" | jq -r '.cli')"
assert_eq "and records the headless fallback backend" "headless" \
  "$(_ccs_dispatch_jsonl_latest "$hid" | jq -r '.backend')"
rm -rf "$hbin" "$hproj"; unset CCS_DISPATCH_BACKEND

test_summary
