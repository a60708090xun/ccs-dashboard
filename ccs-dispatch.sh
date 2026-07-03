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

# agent-pager backend — STAGE 1 STUB.
# Stage 2 will write a local-channel inbound launch and map the worker
# lifecycle back into jobs.jsonl. Until then this always fails so the
# dispatcher falls back to headless.
_ccs_dispatch_spawn_agentpager() {
  echo "ccs-dispatch: agent-pager backend not yet implemented (stage 2)," \
       "falling back to headless" >&2
  return 2
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
  local jid
  for jid in $jids; do
    local latest_status
    latest_status=$(grep "\"job_id\":\"$jid\"" "$jobs_file" | tail -1 | jq -r '.status')
    [ "$latest_status" = "running" ] || continue

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
    .[] | "\(.job_id)  \((.backend // "?") | .[0:10] | . + " " * (10 - length))  \(.status | .[0:9] | . + " " * (9 - length))  \(.task | .[0:$tl])"
  '
}

_ccs_jobs_show_single() {
  local job_id="$1"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local md="$dispatch_dir/results/${job_id}.md"

  if [ -f "$md" ]; then
    cat "$md"
  else
    local record
    record=$(_ccs_dispatch_jsonl_latest "$job_id")
    if [ -n "$record" ]; then
      echo "$record" | jq .
    else
      echo "Job not found: $job_id" >&2
      return 1
    fi
  fi
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
