#!/usr/bin/env bash
# ccs-dispatch.sh — Session dispatch: ccs-dispatch + ccs-jobs
# Sourced by ccs-dashboard.sh

# ── Configurable parameters ──
CCS_DISPATCH_SYNC_TIMEOUT="${CCS_DISPATCH_SYNC_TIMEOUT:-120}"
CCS_DISPATCH_TIMEOUT="${CCS_DISPATCH_TIMEOUT:-600}"
CCS_DISPATCH_JOBS_LIMIT="${CCS_DISPATCH_JOBS_LIMIT:-20}"
CCS_DISPATCH_TASK_DISPLAY_LEN="${CCS_DISPATCH_TASK_DISPLAY_LEN:-60}"
CCS_DISPATCH_RESULT_TTL_DAYS="${CCS_DISPATCH_RESULT_TTL_DAYS:-7}"
CCS_DISPATCH_SUMMARY_LINES="${CCS_DISPATCH_SUMMARY_LINES:-30}"
CCS_DISPATCH_SUMMARY_MAX_CHARS="${CCS_DISPATCH_SUMMARY_MAX_CHARS:-200}"
CCS_DISPATCH_MAX_CONCURRENT_WARN="${CCS_DISPATCH_MAX_CONCURRENT_WARN:-3}"

# ── Backend selection ──
# Returns 0 if the agent-pager backend is usable, 1 otherwise.
# Requires the daemon active and the local-channel spool present, then
# applies Hybrid Detection (design Decision A):
#   same-uid  — spool owned by the caller (personal workflow): the caller
#               already has full access, so skip the claude-broker group
#               and setgid checks; daemon + inbound/ is enough.
#   cross-uid — spool owned by another user (shared seat): enforce the
#               strict AVer checks — caller in the claude-broker group and
#               the inbound spool carrying that group (setgid evidence).
_ccs_dispatch_agentpager_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user is-active --quiet agent-pager.service 2>/dev/null || return 1
  local pager_dir="${AGENT_PAGER_DIR:-$HOME/.agent-pager}"
  [ -d "$pager_dir" ] || return 1
  [ -d "$pager_dir/inbound" ] || return 1

  # same-uid personal workflow: caller owns the spool -> trust it.
  [ "$(stat -c %u "$pager_dir" 2>/dev/null)" = "$(id -u)" ] && return 0

  # cross-uid shared seat: strict group + setgid verification.
  id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx claude-broker || return 1
  [ "$(stat -c %G "$pager_dir/inbound" 2>/dev/null)" = "claude-broker" ] || return 1
  return 0
}

# Echoes the backend to use: "headless" or "agentpager".
# CCS_DISPATCH_BACKEND: auto (default) | agentpager | headless.
_ccs_dispatch_resolve_backend() {
  local choice="${CCS_DISPATCH_BACKEND:-auto}"
  case "$choice" in
    headless|agentpager) printf '%s\n' "$choice" ;;
    auto)
      if _ccs_dispatch_agentpager_available; then
        printf 'agentpager\n'
      else
        printf 'headless\n'
      fi ;;
    *) printf 'headless\n' ;;
  esac
}

# ── Data directory ──
_ccs_dispatch_dir() {
  local dir
  dir="$(_ccs_data_dir)/dispatch"
  mkdir -p "$dir/results" "$dir/pids"
  echo "$dir"
}

# ── Job ID: d-YYYYMMDD-HHMMSS-XXXX ──
_ccs_dispatch_job_id() {
  printf 'd-%s-%s' \
    "$(date +%Y%m%d-%H%M%S)" \
    "$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# Append a job record to jobs.jsonl
_ccs_dispatch_jsonl_append() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  echo "$1" >> "$dispatch_dir/jobs.jsonl"
}

# Read merged record for a job_id (reduce-merge: all fields, later wins)
_ccs_dispatch_jsonl_latest() {
  local job_id="$1"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local f="$dispatch_dir/jobs.jsonl"
  [ -f "$f" ] || return 1
  grep "\"job_id\":\"${job_id}\"" "$f" \
    | jq -s 'reduce .[] as $r ({}; . + $r)'
}

_ccs_dispatch_finish() {
  local job_id="$1" exit_code="$2"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local raw="$dispatch_dir/results/${job_id}.raw"
  local err="$dispatch_dir/results/${job_id}.err"
  local md="$dispatch_dir/results/${job_id}.md"
  local prompt_f="$dispatch_dir/results/${job_id}.prompt"

  # Determine status
  local status
  case "$exit_code" in
    0)   status="completed" ;;
    124) status="timeout" ;;
    *)   status="failed" ;;
  esac

  # Read task from prompt file
  local task=""
  [ -f "$prompt_f" ] && task=$(head -c 200 "$prompt_f")

  # Read initial record for metadata
  local initial
  initial=$(_ccs_dispatch_jsonl_latest "$job_id")
  local project created_at
  project=$(echo "$initial" | jq -r '.project // "unknown"')
  created_at=$(echo "$initial" | jq -r '.created_at // "unknown"')
  local backend
  backend=$(echo "$initial" | jq -r '.backend // "headless"')
  local finished_at
  finished_at=$(date -Iseconds)

  # Calculate duration
  local duration_s=""
  if [ "$created_at" != "unknown" ]; then
    local start_epoch end_epoch
    start_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "")
    end_epoch=$(date +%s)
    if [ -n "$start_epoch" ]; then
      duration_s="$((end_epoch - start_epoch))s"
    fi
  fi

  # Build structured markdown
  {
    echo "# Dispatch Result: $job_id"
    echo ""
    echo "- **Project:** $project"
    echo "- **Task:** $task"
    echo "- **Status:** $status"
    echo "- **Exit code:** $exit_code"
    echo "- **Backend:** $backend"
    echo "- **Created:** $created_at"
    echo "- **Finished:** $finished_at"
    [ -n "$duration_s" ] && echo "- **Duration:** $duration_s"
    echo ""
    echo "## Output"
    echo ""
    if [ -f "$raw" ] && [ -s "$raw" ]; then
      cat "$raw"
    else
      echo "(no output)"
    fi
    echo ""
    echo "## Errors"
    echo ""
    if [ -f "$err" ] && [ -s "$err" ]; then
      cat "$err"
    else
      echo "(none)"
    fi
  } > "$md"

  # Extract summary
  local summary=""
  if [ -f "$raw" ]; then
    summary=$(tail -n "$CCS_DISPATCH_SUMMARY_LINES" "$raw" | head -c "$CCS_DISPATCH_SUMMARY_MAX_CHARS")
  fi

  # Update JSONL
  _ccs_dispatch_jsonl_append "$(jq -nc \
    --arg jid "$job_id" \
    --arg st "$status" \
    --arg ec "$exit_code" \
    --arg fa "$finished_at" \
    --arg sum "$summary" \
    '{job_id:$jid, status:$st, exit_code:($ec|tonumber), finished_at:$fa, summary:$sum}'
  )"

  # Cleanup temp files — keep .err for debugging
  rm -f "$dispatch_dir/pids/${job_id}.pid"
  [ -f "$md" ] && rm -f "$raw"
  rm -f "$prompt_f"
}

# Consume a framed agent-pager local-channel stream and emit each frame's
# BODY to stdout (one per frame, newline-joined). Label is ignored — ccs
# surfaces body only. Reads $1 (file path) or stdin.
# Frame layout (agent-pager notify-send.sh local sink):
#   <RS>MSG<US><LABEL><RS>\n<BODY>\n<RS>END<RS>\n   (RS=0x1E, US=0x1F)
_ccs_consume_framed_stream() {
  local src="${1:-/dev/stdin}"
  awk -v RS=$'\x1e' -v us=$'\x1f' '
    BEGIN { in_msg=0; expect_body=0; n=0 }
    $0 ~ "^MSG" us        { in_msg=1; expect_body=1; next }
    in_msg && expect_body { body=$0; sub(/^\n/,"",body); sub(/\n$/,"",body); expect_body=0; next }
    in_msg && $0 ~ "^END" { bodies[n++]=body; in_msg=0 }
    END { for (i=0;i<n;i++) { if (i) printf "\n"; printf "%s", bodies[i] } printf "\n" }
  ' "$src"
}

# Map an absolute project_dir to the lead-side proj key that ccs writes
# into the inbound .md. ccs keeps its OWN map (key = abspath, same format
# as the lead whitelist) via CCS_DISPATCH_PROJ_MAP so it never reads the
# lead's projects file. Echoes the key; rc 1 if no map / no match.
_ccs_dispatch_resolve_proj_from_dir() {
  local dir="${1%/}" line key val
  local map_file="${CCS_DISPATCH_PROJ_MAP:-$HOME/.config/ccs-dashboard/proj-map}"
  [ -f "$map_file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    [ "${val%/}" = "$dir" ] && { printf '%s\n' "$key"; return 0; }
  done < "$map_file"
  return 1
}

# ── agent-pager backend (stage 2) ──────────────────────────────────────────
# Dispatch a worker over the agent-pager local channel: write an inbound launch,
# then watch the per-user out.stream + the worker's handoff file back into a job
# result. Completion is signalled by the worker writing tmp/handoff-<job_id>.md
# (design Decision B): ccs then stops the seat and finalizes. There is NO
# wall-clock kill — a stuck worker stays up for the operator to /stop (design D2).

# Build the worker's opening prompt: the dispatch prompt plus a handoff-gating
# invariant that tells the worker to write tmp/handoff-<job_id>.md when done
# (that file is ccs's completion signal). ccs-handoff's own default output path
# differs, so the worker is told to save to this exact per-job path.
_ccs_dispatch_agentpager_prompt() {
  local job_id="$1" task="$2"
  cat <<HGRULE
${task}

---
DISPATCH HANDOFF RULE (job ${job_id}, non-negotiable):
This is a dispatched worker session. When the task above is fully complete (or
before your context fills), first report a one-line summary of what you did.
Then, AS YOUR VERY LAST ACTION, write a concise handoff to the file
tmp/handoff-${job_id}.md (path relative to the project root; use ccs-handoff for
the content if helpful). Writing that file is your completion signal: the
dispatcher watches for tmp/handoff-${job_id}.md and closes this session once it
appears, so do not create it until everything else — including your summary — is
already done. You do NOT need to exit yourself.
HGRULE
}

# Write an agent-pager inbound launch file. Frontmatter matches inbound-handler.sh
# (kind/slot/proj/cli + two --- delimiters, body after the second). ccs passes a
# proj KEY only — agent-pager resolves it to a path from its own whitelist (the
# RCE boundary). Echoes the file path; rc 1 on write failure.
_ccs_dispatch_agentpager_launch_file() {
  local job_id="$1" proj="$2" key="$3" prompt="$4" pager_dir="$5"
  local inbound="$pager_dir/inbound"
  mkdir -p "$inbound" || return 1
  local f="$inbound/$(date +%s)-${job_id}.md"
  {
    printf -- '---\n'
    printf 'kind: launch\n'
    printf 'slot: %s\n' "$key"
    printf 'proj: %s\n' "$proj"
    printf 'cli: claude\n'
    printf -- '---\n'
    printf '%s\n' "$prompt"
  } > "$f" || return 1
  printf '%s\n' "$f"
}

# Write an agent-pager inbound stop file to reclaim the local seat. Echoes the
# path; rc 1 on write failure.
_ccs_dispatch_agentpager_stop_file() {
  local key="$1" pager_dir="$2"
  local inbound="$pager_dir/inbound"
  mkdir -p "$inbound" || return 1
  local f="$inbound/$(date +%s%N)-${key}-stop.md"
  {
    printf -- '---\n'
    printf 'kind: stop\n'
    printf 'slot: %s\n' "$key"
    printf -- '---\n'
  } > "$f" || return 1
  printf '%s\n' "$f"
}

# Decode only this job's frames from the per-user out.stream. The stream is
# append-only and persists across jobs, so we read from the byte offset captured
# at launch, not the whole file.
_ccs_dispatch_agentpager_collect() {
  local stream="$1" offset="$2" dest="$3"
  if [ -f "$stream" ]; then
    tail -c +$((offset + 1)) "$stream" | _ccs_consume_framed_stream > "$dest"
  else
    : > "$dest"
  fi
}

# True while the worker's tmux session is alive. Wrapped so tests can mock tmux.
_ccs_dispatch_agentpager_session_alive() {
  tmux has-session -t "$1" 2>/dev/null
}

# Echo the last-activity timestamp (ISO) of a local session = mtime of its
# out.stream. Lets ccs-jobs surface a stalled worker so the operator can /stop
# it (design D2: no auto-kill). Empty if the stream does not exist yet.
_ccs_dispatch_agentpager_last_activity() {
  local key="$1" pager_dir="$2"
  local stream="$pager_dir/channels/$key/out.stream"
  [ -f "$stream" ] || return 0
  date -Iseconds -r "$stream" 2>/dev/null
}

# Finalize an agent-pager job (handoff gating). Handoff file present + copied ->
# handoff-ready (captured to results/<job_id>.handoff). Otherwise the status is
# $3 (no_handoff_status, default "completed"; the monitor passes "failed" when
# the worker session was never observed). ccs is not the worker's parent, so
# there is no exit code. $4 is an optional operator note appended to md + jsonl.
_ccs_dispatch_finish_agentpager() {
  local job_id="$1" handoff_src="$2"
  local no_handoff_status="${3:-completed}" note="${4:-}"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local raw="$dispatch_dir/results/${job_id}.raw"
  local err="$dispatch_dir/results/${job_id}.err"
  local md="$dispatch_dir/results/${job_id}.md"
  local handoff_dst="$dispatch_dir/results/${job_id}.handoff"
  local prompt_f="$dispatch_dir/results/${job_id}.prompt"

  # handoff-ready only when the file is actually captured; a failed copy must not
  # claim a handoff it did not save.
  local status handoff_flag=false
  if [ -f "$handoff_src" ] && cp "$handoff_src" "$handoff_dst" 2>/dev/null; then
    handoff_flag=true
    status="handoff-ready"
  else
    [ -f "$handoff_src" ] && note="${note:+$note; }handoff present but copy failed"
    status="$no_handoff_status"
  fi

  local task=""
  [ -f "$prompt_f" ] && task=$(head -c 200 "$prompt_f")
  local initial project created_at backend
  initial=$(_ccs_dispatch_jsonl_latest "$job_id")
  project=$(echo "$initial" | jq -r '.project // "unknown"')
  created_at=$(echo "$initial" | jq -r '.created_at // "unknown"')
  backend=$(echo "$initial" | jq -r '.backend // "agentpager"')
  local finished_at
  finished_at=$(date -Iseconds)

  local duration_s=""
  if [ "$created_at" != "unknown" ]; then
    local start_epoch
    start_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "")
    [ -n "$start_epoch" ] && duration_s="$(( $(date +%s) - start_epoch ))s"
  fi

  {
    echo "# Dispatch Result: $job_id"
    echo ""
    echo "- **Project:** $project"
    echo "- **Task:** $task"
    echo "- **Status:** $status"
    echo "- **Backend:** $backend"
    echo "- **Created:** $created_at"
    echo "- **Finished:** $finished_at"
    [ -n "$duration_s" ] && echo "- **Duration:** $duration_s"
    [ "$handoff_flag" = true ] && echo "- **Handoff:** $handoff_dst"
    [ -n "$note" ] && echo "- **Note:** ⚠️ $note"
    echo ""
    echo "## Output"
    echo ""
    # A zero-frame stream collects to a lone newline, so test emptiness by
    # non-whitespace content, not just file size.
    if [ -f "$raw" ] && grep -q '[^[:space:]]' "$raw" 2>/dev/null; then
      cat "$raw"
    else
      echo "(no output)"
    fi
    echo ""
    echo "## Errors"
    echo ""
    if [ -f "$err" ] && [ -s "$err" ]; then
      cat "$err"
    else
      echo "(none)"
    fi
  } > "$md"

  local summary=""
  if [ -f "$raw" ]; then
    summary=$(tail -n "$CCS_DISPATCH_SUMMARY_LINES" "$raw" | head -c "$CCS_DISPATCH_SUMMARY_MAX_CHARS")
  fi

  _ccs_dispatch_jsonl_append "$(jq -nc \
    --arg jid "$job_id" \
    --arg st "$status" \
    --arg fa "$finished_at" \
    --arg sum "$summary" \
    --arg note "$note" \
    --argjson ho "$handoff_flag" \
    '{job_id:$jid, status:$st, finished_at:$fa, summary:$sum, handoff:$ho}
     + (if $note == "" then {} else {note:$note} end)'
  )"

  rm -f "$dispatch_dir/pids/${job_id}.pid"
  [ -f "$md" ] && rm -f "$raw"
  rm -f "$prompt_f"
}

# Background monitor for one agent-pager job. Runs under nohup from spawn. Polls
# for the handoff file; when it appears, stops the seat and finalizes. Also exits
# the loop if the worker's tmux session disappears on its own (self /exit or
# crash). No wall-clock timeout (design D2: never auto-kill).
_ccs_dispatch_agentpager_monitor() {
  local job_id="$1" key="$2" project_dir="$3" start_offset="$4" pager_dir="$5"
  local tmux_session="agent-pager-$key"
  local stream="$pager_dir/channels/$key/out.stream"
  local state_json="$pager_dir/state/sessions/$key.json"
  local handoff_src="$project_dir/tmp/handoff-${job_id}.md"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local poll="${CCS_DISPATCH_AGENTPAGER_POLL:-3}"
  local startup="${CCS_DISPATCH_AGENTPAGER_STARTUP:-60}"
  local stop_wait="${CCS_DISPATCH_AGENTPAGER_STOP_WAIT:-30}"
  local observed=0 note=""

  # Phase A — startup grace. The runner spawns the worker's tmux session a few
  # seconds after ccs writes the launch, so has-session is false right now.
  # Wait for it to appear before the completion loop; otherwise the monitor would
  # read "already gone" and finalize before the worker even runs.
  local waited=0
  while [ "$waited" -lt "$startup" ]; do
    if _ccs_dispatch_agentpager_session_alive "$tmux_session"; then observed=1; break; fi
    [ -f "$handoff_src" ] && break
    sleep 1; waited=$((waited + 1))
  done

  # Watch the cwd agent-pager ACTUALLY resolved the proj key to (its state json),
  # not ccs's project_dir. This is the single source of truth for where the worker
  # runs, so the handoff path can never drift from a stale proj-map entry.
  if [ -r "$state_json" ]; then
    local real_cwd
    real_cwd="$(jq -r '.cwd // empty' "$state_json" 2>/dev/null)"
    [ -n "$real_cwd" ] && [ -d "$real_cwd" ] && \
      handoff_src="$real_cwd/tmp/handoff-${job_id}.md"
  fi

  # Phase B — completion. Handoff file appears -> stop the seat; or the worker
  # ends the session on its own. No wall-clock kill (design D2).
  while _ccs_dispatch_agentpager_session_alive "$tmux_session"; do
    observed=1
    if [ -f "$handoff_src" ]; then
      # The worker writes the handoff mid-turn, but its tool/prose frames only
      # relay to out.stream at turn end. Wait for the stream to settle before
      # stopping, or an eager stop truncates the captured output (E2E-observed).
      _ccs_dispatch_agentpager_wait_settle "$stream"
      # Reclaim the seat. If the first stop is not honored (worker mid-tool-call),
      # retry once; if it still will not die, leave a note so the operator knows
      # to reclaim manually rather than silently orphaning the single per-user seat.
      _ccs_dispatch_agentpager_stop_file "$key" "$pager_dir" >/dev/null
      _ccs_dispatch_agentpager_wait_gone "$tmux_session" "$stop_wait"
      if _ccs_dispatch_agentpager_session_alive "$tmux_session"; then
        _ccs_dispatch_agentpager_stop_file "$key" "$pager_dir" >/dev/null
        _ccs_dispatch_agentpager_wait_gone "$tmux_session" "$stop_wait"
        _ccs_dispatch_agentpager_session_alive "$tmux_session" && \
          note="worker session did not stop; reclaim manually (tmux $tmux_session)"
      fi
      break
    fi
    sleep "$poll"
  done
  sleep 1  # let any trailing frames flush to the stream
  _ccs_dispatch_agentpager_collect "$stream" "$start_offset" \
    "$dispatch_dir/results/${job_id}.raw"
  # A session that never appeared is a launch failure, not a clean completion.
  local no_handoff_status="completed"
  [ "$observed" = 0 ] && no_handoff_status="failed"
  _ccs_dispatch_finish_agentpager "$job_id" "$handoff_src" "$no_handoff_status" "$note"
}

# Poll until the tmux session is gone or $2 seconds elapse. Extracted so the
# stop-reclaim path stays readable and the wait bound is testable.
_ccs_dispatch_agentpager_wait_gone() {
  local session="$1" limit="$2" waited=0
  while _ccs_dispatch_agentpager_session_alive "$session" && [ "$waited" -lt "$limit" ]; do
    sleep 1; waited=$((waited + 1))
  done
}

# Wait for the out.stream ($1) to stop growing (turn-end relay flushed), so a
# fast worker's frames are captured before we stop it. Breaks after the size is
# stable for QUIET consecutive checks, or after SETTLE seconds regardless.
_ccs_dispatch_agentpager_wait_settle() {
  local stream="$1"
  local grace="${CCS_DISPATCH_AGENTPAGER_SETTLE:-8}"
  local quiet="${CCS_DISPATCH_AGENTPAGER_SETTLE_QUIET:-2}"
  local last=-1 stable=0 waited=0 sz
  while [ "$waited" -lt "$grace" ]; do
    sz=0; [ -f "$stream" ] && sz="$(stat -c %s "$stream" 2>/dev/null || echo 0)"
    if [ "$sz" = "$last" ]; then
      stable=$((stable + 1)); [ "$stable" -ge "$quiet" ] && break
    else
      stable=0; last="$sz"
    fi
    sleep 1; waited=$((waited + 1))
  done
}

# agent-pager backend spawn. Async-only: writes an inbound launch and starts a
# background monitor, returning immediately. Returns 2 (dispatcher falls back to
# headless) for --sync, an unresolvable proj key, or an inbound write failure.
_ccs_dispatch_spawn_agentpager() {
  local job_id="$1" project_dir="$2" prompt="$3" timeout_secs="$4" mode="$5"

  if [ "$mode" = "sync" ]; then
    echo "ccs-dispatch: agent-pager backend is async-only;" \
         "falling back to headless for --sync" >&2
    return 2
  fi

  local proj
  if ! proj="$(_ccs_dispatch_resolve_proj_from_dir "$project_dir")"; then
    echo "ccs-dispatch: no proj-map entry for $project_dir" \
         "(set \$CCS_DISPATCH_PROJ_MAP or ~/.config/ccs-dashboard/proj-map);" \
         "falling back to headless" >&2
    return 2
  fi

  local pager_dir="${AGENT_PAGER_DIR:-$HOME/.agent-pager}"
  local luser key stream start_offset=0
  luser="$(id -un)"
  key="local-$luser"

  # Single-worker per user (key local-<user>): a second concurrent dispatch would
  # share the same tmux session + out.stream and corrupt both jobs' output. Refuse
  # and fall back to headless while one is already running (multi-worker is v2).
  if _ccs_dispatch_agentpager_session_alive "agent-pager-$key"; then
    echo "ccs-dispatch: a local agent-pager worker (agent-pager-$key) is already" \
         "running; falling back to headless" >&2
    return 2
  fi

  stream="$pager_dir/channels/$key/out.stream"
  [ -f "$stream" ] && start_offset="$(stat -c %s "$stream" 2>/dev/null || echo 0)"

  local worker_prompt launch_file
  worker_prompt="$(_ccs_dispatch_agentpager_prompt "$job_id" "$prompt")"
  if ! launch_file="$(_ccs_dispatch_agentpager_launch_file \
        "$job_id" "$proj" "$key" "$worker_prompt" "$pager_dir")"; then
    echo "ccs-dispatch: failed to write agent-pager launch;" \
         "falling back to headless" >&2
    return 2
  fi

  local dispatch_dir script_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
  printf '%s' "$prompt" > "$dispatch_dir/results/${job_id}.prompt"

  if [ "${CCS_DISPATCH_AGENTPAGER_MONITOR:-1}" = "1" ]; then
    nohup bash -c '
      source "$6/ccs-dashboard.sh"
      _ccs_dispatch_agentpager_monitor "$1" "$2" "$3" "$4" "$5"
    ' _ "$job_id" "$key" "$project_dir" "$start_offset" "$pager_dir" "$script_dir" \
      > /dev/null 2>&1 &
    echo $! > "$dispatch_dir/pids/${job_id}.pid"
    disown
  fi
  return 0
}

_ccs_dispatch_spawn_headless() {
  local job_id="$1" project_dir="$2" prompt="$3"
  local timeout_secs="$4" mode="$5"
  local dispatch_dir script_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"

  # Write prompt to temp file (avoid shell injection)
  local prompt_file="$dispatch_dir/results/${job_id}.prompt"
  printf '%s' "$prompt" > "$prompt_file"

  if [ "$mode" = "sync" ]; then
    local rc=0
    (cd "$project_dir" && \
      timeout "$timeout_secs" claude -p "$(cat "$prompt_file")") \
      > "$dispatch_dir/results/${job_id}.raw" \
      2> "$dispatch_dir/results/${job_id}.err" \
      || rc=$?
    _ccs_dispatch_finish "$job_id" "$rc"
    return $rc
  else
    nohup bash -c '
      prompt=$(cat "$1")
      cd "$2" && \
      timeout "$3" claude -p "$prompt" \
        > "$4/results/$5.raw" \
        2> "$4/results/$5.err"
      rc=$?
      source "$6/ccs-dashboard.sh"
      _ccs_dispatch_finish "$5" $rc
    ' _ \
      "$prompt_file" \
      "$project_dir" \
      "$timeout_secs" \
      "$dispatch_dir" \
      "$job_id" \
      "$script_dir" \
      > /dev/null 2>&1 &
    echo $! > "$dispatch_dir/pids/${job_id}.pid"
    disown
  fi
}

# Dispatcher: pick backend, route, fall back to headless on agent-pager failure.
# Optional $6 = pre-resolved backend (avoids double-resolve from ccs-dispatch).
_ccs_dispatch_spawn() {
  local job_id="$1" project_dir="$2" prompt="$3"
  local timeout_secs="$4" mode="$5"
  local backend="${6:-$(_ccs_dispatch_resolve_backend)}"

  _CCS_DISPATCH_LAST_BACKEND="$backend"
  if [ "$backend" = "agentpager" ]; then
    if _ccs_dispatch_spawn_agentpager \
         "$job_id" "$project_dir" "$prompt" "$timeout_secs" "$mode"; then
      return 0
    fi
    _CCS_DISPATCH_LAST_BACKEND="headless"  # agent-pager failed -> fell back
  fi
  _ccs_dispatch_spawn_headless \
    "$job_id" "$project_dir" "$prompt" "$timeout_secs" "$mode"
}

_ccs_dispatch_lazy_cleanup() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local ttl="$CCS_DISPATCH_RESULT_TTL_DAYS"
  find "$dispatch_dir/results" -type f -mtime +"$ttl" -delete 2>/dev/null
  local pidfile
  for pidfile in "$dispatch_dir/pids"/*.pid; do
    [ -f "$pidfile" ] || continue
    kill -0 "$(cat "$pidfile")" 2>/dev/null || rm -f "$pidfile"
  done
  find "$dispatch_dir/results" -type f \
    \( -name "*.raw" -o -name "*.prompt" \) \
    -mmin +60 -delete 2>/dev/null
}

_ccs_dispatch_running_count() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local count=0
  local pidfile
  for pidfile in "$dispatch_dir/pids"/*.pid; do
    [ -f "$pidfile" ] || continue
    kill -0 "$(cat "$pidfile")" 2>/dev/null && count=$((count + 1))
  done
  echo "$count"
}

_ccs_dispatch_context() {
  local project_dir="$1"
  local ctx=""
  if git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
    local branch uncommitted
    branch=$(git -C "$project_dir" branch --show-current 2>/dev/null)
    uncommitted=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ctx+="[Project: $project_dir]"$'\n'
    ctx+="[Git branch: $branch, uncommitted: $uncommitted files]"$'\n'
  fi
  ctx+=$'\n---\n'
  echo "$ctx"
}

# Returns a verification rule prepended to every dispatch prompt.
# Guards against Opus 4.8 tool-output confabulation (fabricated success narratives).
# See docs/case-studies/2026-06-23-opus-fabricated-output.md for root-cause analysis.
_ccs_dispatch_verification_rule() {
  cat <<'VRULE'
VERIFICATION RULE (applies to this entire session, non-negotiable):
After every tool call that creates or modifies an external resource —
gh issue create, gh pr create, git commit, git push, Write, Edit — you MUST:
1. Quote the exact tool_result line that confirms success before marking
   the step done.
2. Do NOT report a commit hash, PR URL, issue URL, or "file written"
   unless that exact string appears verbatim in a preceding tool_result.
3. If tool_result shows an error, exit code != 0, or only a bare URL
   (with no additional confirmation text), report the failure immediately.
   Never substitute a fabricated success narrative.
Completion pressure does not override this rule.
A reported failure is always preferable to a fabricated success.
---
VRULE
}

ccs-dispatch() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
ccs-dispatch — dispatch task to Claude Code

Usage:
  ccs-dispatch --project <dir> "task"
  ccs-dispatch --sync --project <dir> "task"

Options:
  --sync           Blocking (default: async)
  --context        Inject git status + todos
  --timeout <secs> Override timeout
  --project <dir>  Target project (required)
HELP
    return 0
  fi

  _ccs_dispatch_lazy_cleanup

  local mode="async" context=false
  local timeout_secs="" project="" task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --sync) mode="sync"; shift ;;
      --context) context=true; shift ;;
      --timeout) timeout_secs="$2"; shift 2 ;;
      --project) project="$2"; shift 2 ;;
      *) task="$1"; shift ;;
    esac
  done

  if [ -z "$project" ]; then
    echo "Error: --project is required" >&2; return 1
  fi
  if [ -z "$task" ]; then
    echo "Error: task description required" >&2; return 1
  fi
  if [ ! -d "$project" ]; then
    echo "Error: $project not found" >&2; return 1
  fi

  project="$(cd "$project" && pwd)"

  if [ -z "$timeout_secs" ]; then
    if [ "$mode" = "sync" ]; then
      timeout_secs="$CCS_DISPATCH_SYNC_TIMEOUT"
    else
      timeout_secs="$CCS_DISPATCH_TIMEOUT"
    fi
  fi

  local running
  running=$(_ccs_dispatch_running_count)
  if [ "$running" -ge "$CCS_DISPATCH_MAX_CONCURRENT_WARN" ]; then
    echo "Warning: $running jobs running" >&2
  fi

  local _vrule
  _vrule="$(_ccs_dispatch_verification_rule)"
  local prompt
  if $context; then
    prompt="$(_ccs_dispatch_context "$project")${_vrule}Task: $task"
  else
    prompt="${_vrule}Task: $task"
  fi

  local backend
  backend=$(_ccs_dispatch_resolve_backend)
  local job_id
  job_id=$(_ccs_dispatch_job_id)
  _ccs_dispatch_jsonl_append "$(jq -nc \
    --arg jid "$job_id" \
    --arg proj "$project" \
    --arg t "$task" \
    --argjson ctx "$context" \
    --arg m "$mode" \
    --arg be "$backend" \
    --arg ca "$(date -Iseconds)" \
    '{job_id:$jid, project:$proj, task:$t, context_injected:$ctx, mode:$m, backend:$be, status:"running", created_at:$ca}'
  )"

  local spawn_rc=0
  _ccs_dispatch_spawn "$job_id" "$project" "$prompt" \
    "$timeout_secs" "$mode" "$backend" || spawn_rc=$?

  if [ "${_CCS_DISPATCH_LAST_BACKEND:-$backend}" != "$backend" ]; then
    _ccs_dispatch_jsonl_append "$(jq -nc \
      --arg jid "$job_id" \
      --arg be "$_CCS_DISPATCH_LAST_BACKEND" \
      '{job_id:$jid, backend:$be, fallback:true}')"
  fi

  if [ "$mode" = "sync" ]; then
    local dispatch_dir
    dispatch_dir="$(_ccs_dispatch_dir)"
    local md="$dispatch_dir/results/${job_id}.md"
    if [ -f "$md" ]; then
      echo "Job $job_id completed. Result: $md"
    else
      echo "Job $job_id finished (no result)."
    fi
  else
    echo "Job dispatched: $job_id"
    echo "Check: ccs-jobs $job_id"
  fi
}

ccs-jobs() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
ccs-jobs — view dispatch job history

Usage:
  ccs-jobs            Recent jobs
  ccs-jobs --all      All jobs
  ccs-jobs <job-id>   Single job detail
HELP
    return 0
  fi

  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local jobs_file="$dispatch_dir/jobs.jsonl"

  if [ ! -f "$jobs_file" ]; then
    echo "No dispatch jobs found."
    return 0
  fi

  _ccs_jobs_sync_status

  local show_all=false single_id=""
  case "${1:-}" in
    --all) show_all=true ;;
    "") ;;
    *)  single_id="$1" ;;
  esac

  if [ -n "$single_id" ]; then
    _ccs_jobs_show_single "$single_id"
  else
    _ccs_jobs_show_list "$show_all"
  fi
}

_ccs_jobs_sync_status() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local jobs_file="$dispatch_dir/jobs.jsonl"
  [ -f "$jobs_file" ] || return 0

  local jids
  jids=$(jq -r 'select(.status=="running") | .job_id' "$jobs_file" | sort -u)

  # Which running agentpager job owns the (per-user, shared-name) tmux session:
  # the newest by created_at. The spawn guard admits at most one live worker, so
  # older running agentpager records are stale (monitor died before finalizing).
  local newest_ap_jid
  newest_ap_jid=$(jq -rs '
    group_by(.job_id) | map(reduce .[] as $r ({}; . + $r))
    | map(select(.status=="running" and .backend=="agentpager"))
    | sort_by(.created_at) | reverse | .[0].job_id // empty' "$jobs_file")

  local key="local-$(id -un)"
  local jid
  for jid in $jids; do
    # Effective status = reduce-merge (consistent with the board's show_list),
    # not tail -1 of the last raw record — a trailing fallback marker has no
    # status field and would otherwise read as null and skip this job.
    local merged status backend
    merged=$(_ccs_dispatch_jsonl_latest "$jid")
    status=$(echo "$merged" | jq -r '.status // ""')
    [ "$status" = "running" ] || continue
    backend=$(echo "$merged" | jq -r '.backend // "headless"')

    if [ "$backend" = "agentpager" ]; then
      # Agentpager: the worker's tmux session — not the background monitor's pid —
      # is the liveness signal (the monitor can die independently of the worker).
      if _ccs_dispatch_agentpager_session_alive "agent-pager-$key"; then
        [ "$jid" = "$newest_ap_jid" ] && continue   # live worker, still running
        _ccs_dispatch_jsonl_append "$(jq -nc \
          --arg jid "$jid" --arg fa "$(date -Iseconds)" \
          '{job_id:$jid, status:"completed", finished_at:$fa,
            note:"superseded; monitor exited"}')"
        continue
      fi
      # Session gone. The monitor normally finalizes; if it did (md present),
      # leave it alone. If not, reconcile to completed without doing the monitor's
      # heavy finalize (stream/handoff capture) — design Q1=C keeps sync light.
      [ -f "$dispatch_dir/results/${jid}.md" ] && continue
      _ccs_dispatch_jsonl_append "$(jq -nc \
        --arg jid "$jid" --arg fa "$(date -Iseconds)" \
        '{job_id:$jid, status:"completed", finished_at:$fa,
          note:"monitor exited without finalizing; session gone"}')"
      continue
    fi

    # Headless (unchanged): the pidfile IS the worker; dead pid + no md = crash.
    local pidfile="$dispatch_dir/pids/${jid}.pid"
    if [ -f "$pidfile" ]; then
      kill -0 "$(cat "$pidfile")" 2>/dev/null && continue
    fi
    local md="$dispatch_dir/results/${jid}.md"
    [ -f "$md" ] && continue
    _ccs_dispatch_jsonl_append "$(jq -nc \
      --arg jid "$jid" \
      --arg fa "$(date -Iseconds)" \
      '{job_id:$jid, status:"failed", exit_code:-1, finished_at:$fa, summary:"process disappeared"}'
    )"
    rm -f "$pidfile"
  done
}

_ccs_jobs_show_list() {
  local show_all="$1"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local jobs_file="$dispatch_dir/jobs.jsonl"
  local limit="$CCS_DISPATCH_JOBS_LIMIT"
  local tlen="$CCS_DISPATCH_TASK_DISPLAY_LEN"

  local deduped
  deduped=$(jq -s \
    'group_by(.job_id) | map(reduce .[] as $r ({}; . + $r))
     | sort_by(.created_at) | reverse' "$jobs_file")

  if [ "$show_all" = "false" ]; then
    deduped=$(echo "$deduped" | jq ".[0:$limit]")
  fi

  local count
  count=$(echo "$deduped" | jq 'length')
  echo "Dispatch Jobs ($count)"
  echo "========================"

  echo "$deduped" | jq -r --argjson tl "$tlen" '
    .[] | "\(.job_id)  \((.backend // "?") | .[0:10] | . + " " * (10 - length))  \(.status | .[0:13] | . + " " * (13 - length))  \(.task | .[0:$tl])"
  '

  # Q2=A: last-activity footer for the newest running agentpager worker (the one
  # that owns the live tmux session). deduped is sorted created_at desc, so the
  # first running+agentpager entry is the newest.
  local running_ap
  running_ap=$(echo "$deduped" | jq -r \
    'map(select(.status=="running" and .backend=="agentpager")) | .[0].job_id // empty')
  if [ -n "$running_ap" ]; then
    _ccs_jobs_agentpager_footer "local-$(id -un)" \
      "${AGENT_PAGER_DIR:-$HOME/.agent-pager}"
  fi
}

_ccs_jobs_show_single() {
  local job_id="$1"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local md="$dispatch_dir/results/${job_id}.md"
  local record
  record=$(_ccs_dispatch_jsonl_latest "$job_id")

  if [ -f "$md" ]; then
    cat "$md"
  elif [ -n "$record" ]; then
    echo "$record" | jq .
    # For a still-running agent-pager worker, surface last-activity (out.stream
    # mtime) so a stalled worker is visible for a manual /stop (design D2).
    local be st
    be=$(echo "$record" | jq -r '.backend // ""')
    st=$(echo "$record" | jq -r '.status // ""')
    if [ "$be" = "agentpager" ] && [ "$st" = "running" ]; then
      local la
      la=$(_ccs_dispatch_agentpager_last_activity \
        "local-$(id -un)" "${AGENT_PAGER_DIR:-$HOME/.agent-pager}")
      [ -n "$la" ] && echo "Last activity: $la"
    fi
  else
    echo "Job not found: $job_id" >&2
    return 1
  fi

  # Q3=A: handoff-ready action hint (applies to both the md and record paths).
  if [ -n "$record" ]; then
    local hint_st hint_proj
    hint_st=$(echo "$record" | jq -r '.status // ""')
    hint_proj=$(echo "$record" | jq -r '.project // "."')
    _ccs_jobs_handoff_hint "$job_id" "$hint_st" "$hint_proj" "$dispatch_dir"
  fi
}

# Echo a one-line last-activity footer for the running agentpager worker so a
# stalled worker is visible on the board for a manual /stop (design D2/Q2=A).
# Single-worker MVP: at most one running agentpager worker, so one line suffices.
_ccs_jobs_agentpager_footer() {
  local key="$1" pager_dir="$2"
  local stream="$pager_dir/channels/$key/out.stream"
  if [ ! -f "$stream" ]; then
    printf '⏱ local worker: no output yet\n'
    return 0
  fi
  local mtime now idle_min iso
  mtime=$(stat -c %Y "$stream" 2>/dev/null) || return 0
  now=$(date +%s)
  idle_min=$(( (now - mtime) / 60 ))
  iso=$(date -Iseconds -d "@$mtime" 2>/dev/null)
  printf '⏱ local worker: last activity %s (%s)\n' "$iso" "$(_ccs_ago_str "$idle_min")"
}

# Echo a handoff-ready action hint: point at the captured .handoff and give a
# project-prefilled chain command. The next task can't be prefilled (it lives in
# the handoff the operator must read), and auto-chaining is v2 (design Q3=A).
_ccs_jobs_handoff_hint() {
  local job_id="$1" status="$2" project="$3" dispatch_dir="$4"
  [ "$status" = "handoff-ready" ] || return 0
  printf '\n'
  printf '→ Handoff ready: %s/results/%s.handoff\n' "$dispatch_dir" "$job_id"
  printf '  Review it, then chain the next worker:\n'
  printf '    ccs-dispatch --project %s "<next task from handoff>"\n' "$project"
  printf '  (auto-chaining is v2)\n'
}

# Generate suggested_actions for a session
# $1: session JSON object (from overview)
# Output: JSON array of actions
_ccs_dispatch_suggest_actions() {
  local session_json="$1"
  echo "$session_json" | jq '
    . as $s |
    ($s.todos // [])
    | [.[] | select(.status == "pending")]
    | if length > 0 then
        [{
          type: "dispatch",
          reason: "pending_todos",
          description: (.[0].content | .[0:80]),
          command: (
            "ccs-dispatch --project "
            + ($s.path // $s.project // ".")
            + " \""
            + .[0].content
            + "\""
          )
        }]
      else []
      end
  '
}
