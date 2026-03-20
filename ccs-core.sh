#!/usr/bin/env bash
# ccs-core.sh — Claude Code Session core helpers and basic commands
# Part of ccs-dashboard. Sourced by ccs-dashboard.sh automatically.
#
# Computed at source time — used to strip $HOME prefix from JSONL directory names.
_CCS_HOME_ENCODED=$(echo "$HOME" | sed 's/\//-/g')
#
# Helpers:
#   _ccs_session_row        — parse JSONL session → tab-separated row
#   _ccs_topic_from_jsonl   — extract topic from JSONL
#   _ccs_resolve_jsonl      — resolve JSONL file from args
#   _ccs_build_pairs_index  — extract prompt-response index
#   _ccs_get_pair           — extract Nth prompt-response pair
#   _ccs_conversation_md    — filtered conversation pairs as markdown
#   _ccs_recent_files_md    — recent file operations from JSONL
#   _ccs_todos_md           — TodoWrite items from JSONL
#   _ccs_resolve_project_path — resolve JSONL dir name → filesystem path
#   _ccs_get_boot_epoch     — system boot time as epoch
#   _ccs_detect_crash       — detect crash-interrupted sessions
#
# Commands:
#   ccs-sessions            — all sessions within N hours
#   ccs-active              — non-archived sessions within N days
#   ccs-cleanup             — kill stopped (suspended) claude processes

# ── Helper: parse one JSONL session file → tab-separated row ──
_ccs_session_row() {
  local f="$1"
  local dir project sid mod now ago ago_str color topic status

  dir=$(basename "$(dirname "$f")")
  project=$(echo "$dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
  [ -z "$project" ] && project="~(home)"

  sid=$(basename "$f" .jsonl | cut -c1-8)

  mod=$(stat -c "%Y" "$f")
  now=$(date +%s)
  ago=$(( (now - mod) / 60 ))
  if [ "$ago" -lt 60 ]; then
    ago_str=$(printf '%3dm ago' "$ago")
  elif [ "$ago" -lt 1440 ]; then
    ago_str=$(printf '%3dh ago' "$((ago / 60))")
  else
    ago_str=$(printf '%3dd ago' "$((ago / 1440))")
  fi

  # Check if session is archived (has last-prompt event near end of file)
  if tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"'; then
    status="archived"
    color="\033[90m\033[9m"  # gray + strikethrough
  elif [ "$ago" -lt 10 ]; then
    status="active"
    color="\033[32m"  # green
  elif [ "$ago" -lt 60 ]; then
    status="recent"
    color="\033[33m"  # yellow
  elif [ "$ago" -lt 1440 ]; then
    status="idle"
    color="\033[34m"  # blue — open but idle (< 1 day)
  else
    status="stale"
    color="\033[90m"  # gray — open but untouched > 1 day
  fi

  # Topic: prefer Happy Coder title (last set), fallback to first user message
  topic=""
  if grep -q "change_title" "$f" 2>/dev/null; then
    topic=$(grep "change_title" "$f" 2>/dev/null | jq -r '
      .message.content[]? |
      select(.type == "tool_use" and .name == "mcp__happy__change_title") |
      .input.title' 2>/dev/null | tail -1)
  fi
  if [ -z "$topic" ]; then
    # Find first real user message (skip meta, local-command, system tags, slash commands)
    topic=$(jq -r '
      select(.type == "user" and (.message.content | type == "string")
        and ((.isMeta // false) == false)
        and (.message.content | test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
        and (.message.content | test("^\\s*$") | not))
      | .message.content
    ' "$f" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c1-120)
  fi
  [ -z "$topic" ] && topic="-"
  # Sanitize for display (no truncation — let terminal wrap)
  topic=$(echo "$topic" | tr '\n\t' '  ')

  # Output: project, ago (for sort), status, color, display line (no ANSI in sort keys)
  printf "%s\t%d\t%s\t%s\t%-35s %-20s %-12s %s\n" "$project" "$ago" "$status" "$color" "$project" "$sid" "$ago_str" "$topic"
}

# ── Helper: resolve topic from JSONL (Happy title or first user msg) ──
_ccs_topic_from_jsonl() {
  local f="$1"
  local topic=""
  if grep -q "change_title" "$f" 2>/dev/null; then
    topic=$(grep "change_title" "$f" 2>/dev/null | jq -r '
      .message.content[]? |
      select(.type == "tool_use" and .name == "mcp__happy__change_title") |
      .input.title' 2>/dev/null | tail -1)
  fi
  if [ -z "$topic" ]; then
    # Find first real user message (skip meta, local-command, system tags, slash commands)
    topic=$(jq -r '
      select(.type == "user" and (.message.content | type == "string")
        and ((.isMeta // false) == false)
        and (.message.content | test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
        and (.message.content | test("^\\s*$") | not))
      | .message.content
    ' "$f" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c1-120)
  fi
  [ -z "$topic" ] && topic="-"
  echo "$topic"
}

# ── Helper: resolve JSONL file from args ──
_ccs_resolve_jsonl() {
  local projects_dir="$HOME/.claude/projects"
  local prefix="$1" search_all="$2"
  if [ -n "$prefix" ]; then
    find "$projects_dir" -maxdepth 2 -name "${prefix}*.jsonl" ! -path "*/subagents/*" 2>/dev/null | head -1
  else
    local search_dir
    if [ "$search_all" = "true" ]; then
      search_dir="$projects_dir"
    else
      local encoded_dir
      encoded_dir=$(pwd | sed 's|/|-|g')
      search_dir="$projects_dir/$encoded_dir"
      [ ! -d "$search_dir" ] && return 1
    fi
    find "$search_dir" -maxdepth 2 -name "*.jsonl" ! -path "*/subagents/*" -printf '%T@\t%p\n' 2>/dev/null \
      | sort -rn | head -1 | cut -f2
  fi
}

# ── Helper: extract prompt-response pairs index from JSONL ──
# Output: tab-separated lines: prompt_line_num \t prompt_text_preview
_ccs_build_pairs_index() {
  local jsonl="$1"
  # Extract all user prompts (string content = real user input, not tool_result)
  # and the next assistant text response after each
  jq -r 'select(.type == "user" and (.message.content | type == "string")) | .message.content | gsub("\n"; " ") | .[:120]' "$jsonl" 2>/dev/null \
    | cat -n
}

# ── Helper: extract the Nth prompt-response pair ──
# Output: two JSON lines: {role:"user", text:...} and {role:"assistant", text:...}
# Faithfully shows only content between the Nth and (N+1)th user prompt.
# Includes tool_use summaries when text is absent (interrupted turns).
_ccs_get_pair() {
  local jsonl="$1" pair_idx="$2"

  # Extract user prompts, assistant text, AND tool_use summaries
  # so interrupted turns still show what the agent was doing
  jq -c '
    if .type == "user" and (.message.content | type == "string") then
      {role: "user", text: .message.content}
    elif .type == "assistant" then
      (.message.content | if type == "array" then
        [.[] | select(.type == "text") | .text] | join("\n")
      else . end) as $t |
      (.message.content | if type == "array" then
        [.[] | select(.type == "tool_use") |
          if .name == "Read" then "📖 Read " + .input.file_path
          elif .name == "Edit" then "✏️ Edit " + .input.file_path
          elif .name == "Write" then "📝 Write " + .input.file_path
          elif .name == "Bash" then "$ " + (.input.command | split("\n") | first | .[:80])
          elif .name == "Grep" then "🔍 Grep " + .input.pattern
          elif .name == "Glob" then "🔍 Glob " + .input.pattern
          elif .name == "Agent" then "🤖 Agent: " + (.input.description // "")
          else "🔧 " + .name end
        ] | join("\n")
      else "" end) as $tools |
      (.message.content | if type == "array" then
        [.[] | select(.type == "thinking") | "💭 (thinking...)"] | join("\n")
      else "" end) as $thinking |
      {role: "assistant", text: $t, tools: $tools, thinking: $thinking}
    else empty end
  ' "$jsonl" 2>/dev/null \
    | jq -sc --argjson idx "$pair_idx" '
      . as $arr |
      [to_entries[] | select(.value.role == "user")] as $users |
      if ($idx < 1 or $idx > ($users | length)) then empty
      else
        $users[$idx - 1].key as $spos |
        (if $idx < ($users | length) then $users[$idx].key else ($arr | length) end) as $epos |
        $arr[$spos],
        # Merge text and tool summaries between this user and next
        ([$arr[$spos + 1 : $epos][] | select(.role == "assistant")] | {
          texts: ([.[].text] | map(select(length > 0)) | join("\n")),
          tools: ([.[].tools] | map(select(length > 0)) | join("\n")),
          thinking: ([.[].thinking] | map(select(length > 0)) | join("\n"))
        }) as $resp |
        if ($resp.texts | length) > 0 then
          {role: "assistant", text: $resp.texts}
        elif ($resp.tools | length) > 0 then
          {role: "assistant", text: ("⚡ interrupted — agent was executing:\n" + $resp.tools)}
        elif ($resp.thinking | length) > 0 then
          {role: "assistant", text: "⚡ interrupted — agent was thinking"}
        else
          {role: "assistant", text: ""}
        end
      end
    '
}

# ── Helper: extract filtered conversation pairs as markdown ──
# Usage: _ccs_conversation_md <jsonl> <pair_count> <max_user_lines> <max_asst_lines>
_ccs_conversation_md() {
  local jsonl="$1" pair_count="${2:-5}" max_ulines="${3:-5}" max_alines="${4:-8}"

  # Build filtered pair indices (reuse ccs-resume-prompt logic)
  local -a real_to_raw=()
  local raw_idx=0
  while IFS=$'\t' read -r is_meta content; do
    raw_idx=$((raw_idx + 1))
    [ "$is_meta" = "true" ] && continue
    case "$content" in
      '<local-command'*|'<command-name'*|'<system-'*) continue ;;
    esac
    [[ "$content" =~ ^[[:space:]]*/exit ]] && continue
    [[ "$content" =~ ^[[:space:]]*/quit ]] && continue
    [ -z "${content// /}" ] && continue
    real_to_raw+=("$raw_idx")
  done < <(jq -r '
    select(.type == "user" and (.message.content | type == "string")) |
    [(.isMeta // false | tostring), (.message.content | .[:80] | gsub("\n"; " "))] |
    @tsv
  ' "$jsonl" 2>/dev/null)

  local real_count=${#real_to_raw[@]}
  local start_from=$((real_count - pair_count + 1))
  [ "$start_from" -lt 1 ] && start_from=1

  local ri
  for ((ri = start_from; ri <= real_count; ri++)); do
    local raw_p=${real_to_raw[$((ri - 1))]}
    local pair_json user_text assistant_text
    pair_json=$(_ccs_get_pair "$jsonl" "$raw_p")
    user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
    assistant_text=$(echo "$pair_json" | tail -1 | jq -r '.text' 2>/dev/null)

    local user_preview asst_preview
    user_preview=$(echo "$user_text" | head -"$max_ulines" | cut -c1-200)
    local ul; ul=$(echo "$user_text" | wc -l)
    [ "$ul" -gt "$max_ulines" ] && user_preview="${user_preview}
..."

    asst_preview=$(echo "$assistant_text" | head -"$max_alines" | cut -c1-200)
    local al; al=$(echo "$assistant_text" | wc -l)
    [ "$al" -gt "$max_alines" ] && asst_preview="${asst_preview}
..."

    printf '**[%d/%d] User:**\n%s\n\n' "$ri" "$real_count" "$user_preview"
    printf '**[%d/%d] Claude:**\n%s\n\n' "$ri" "$real_count" "$asst_preview"
  done
}

# ── Helper: extract recent file operations from JSONL ──
_ccs_recent_files_md() {
  local jsonl="$1"
  jq -r '
    select(.type == "assistant") |
    .message.content[]? |
    select(.type == "tool_use") |
    if .name == "Read" then "R " + .input.file_path
    elif .name == "Edit" then "E " + .input.file_path
    elif .name == "Write" then "W " + .input.file_path
    elif .name == "Bash" then "$ " + (.input.command | split("\n") | first | .[:80])
    else empty end
  ' "$jsonl" 2>/dev/null | tail -15 | sort -u
}

# ── Helper: extract TodoWrite items from JSONL ──
_ccs_todos_md() {
  local jsonl="$1"
  # Find the last TodoWrite call and extract its items
  jq -r '
    select(.type == "assistant") |
    .message.content[]? |
    select(.type == "tool_use" and .name == "TodoWrite") |
    .input.todos[]? |
    (if .status == "completed" then "- [x] " elif .status == "in_progress" then "- [~] " else "- [ ] " end) + .content
  ' "$jsonl" 2>/dev/null | tail -20
}

# ── ccs-sessions [hours] — all sessions within N hours (default 24) ──
ccs-sessions() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-sessions [hours]  — all sessions within N hours (default 24)
[personal tool, not official Claude Code]

Colors:
  green        active (< 10 min)
  yellow       recent (< 1 hour)
  blue         idle, open (< 1 day)
  gray         stale, open (> 1 day)
  g̶r̶a̶y̶ ̶s̶t̶r̶i̶k̶e̶  archived (has last-prompt marker)

Topic source: Happy Coder title if set, otherwise first user message.
HELP
    return 0
  fi
  local projects_dir="$HOME/.claude/projects"
  local hours="${1:-24}"
  local mins=$((hours * 60))
  local prev_project=""

  printf "\033[1m%-35s %-20s %-12s %s\033[0m\n" "PROJECT" "SESSION ID" "LAST ACTIVE" "TOPIC"
  printf '%.0s─' {1..100}; echo

  find "$projects_dir" -maxdepth 2 -name "*.jsonl" -mmin -"$mins" ! -path "*/subagents/*" -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do
    _ccs_session_row "$f"
  done | sort -t$'\t' -k1,1 -k2,2n | while IFS=$'\t' read -r proj _ _ color display; do
    if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
      echo
    fi
    prev_project="$proj"
    printf "${color}%s\033[0m\n" "$display"
  done
}

# ── ccs-active [days] — open (non-archived) sessions within N days (default 7) ──
ccs-active() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-active [days]  — open (non-archived) sessions within N days (default 7)
[personal tool, not official Claude Code]

Colors:
  green        active (< 10 min)
  yellow       recent (< 1 hour)
  blue         idle, open (< 1 day)
  gray         stale, open (> 1 day)

Archived sessions (with last-prompt marker) are excluded.
Topic source: Happy Coder title if set, otherwise first user message.
HELP
    return 0
  fi
  local projects_dir="$HOME/.claude/projects"
  local days="${1:-7}"
  local mins=$((days * 1440))
  local prev_project=""
  local count=0

  printf "\033[1m%-35s %-20s %-12s %s\033[0m\n" "PROJECT" "SESSION ID" "LAST ACTIVE" "TOPIC"
  printf '%.0s─' {1..100}; echo

  # Pass 1: collect non-archived files (fast: only tail | grep)
  local open_files=()
  while IFS= read -r -d '' f; do
    tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"' || open_files+=("$f")
  done < <(find "$projects_dir" -maxdepth 2 -name "*.jsonl" -mmin -"$mins" ! -path "*/subagents/*" -print0 2>/dev/null)

  # Pass 2: full row extraction only for non-archived sessions
  for f in "${open_files[@]}"; do
    _ccs_session_row "$f"
  done | sort -t$'\t' -k1,1 -k2,2n | while IFS=$'\t' read -r proj _ _ color display; do
    if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
      echo
    fi
    prev_project="$proj"
    printf "${color}%s\033[0m\n" "$display"
    count=$((count + 1))
  done

  printf "\n\033[90m%d open sessions (last %d days)\033[0m\n" "${#open_files[@]}" "$days"
}

# ── ccs-cleanup [--dry-run|-n|--force|-f] — kill stopped claude processes ──
ccs-cleanup() {
  local dry_run=false force=false
  for arg in "$@"; do
    case "$arg" in
      --dry-run|-n) dry_run=true ;;
      --force|-f) force=true ;;
      --help|-h)
        cat <<'HELP'
ccs-cleanup [--dry-run|-n] [--force|-f]  — kill stopped (suspended) claude processes
[personal tool, not official Claude Code]

Finds claude processes in Stopped state (Tl/T) and terminates them.
These are typically caused by /exit in waveterm or Ctrl+Z.
Shows PID, RAM, working directory, start/last-active time, and session topic.

  --dry-run, -n   Show what would be killed without doing it
  --force, -f     Skip confirmation prompt
HELP
        return 0 ;;
    esac
  done

  local pids=() total_mb=0
  while IFS= read -r line; do
    local pid rss mb cwd sid topic started last_active
    pid=$(echo "$line" | awk '{print $1}')
    rss=$(echo "$line" | awk '{print $3}')
    mb=$((rss / 1024))
    pids+=("$pid")
    total_mb=$(( total_mb + mb ))

    # Resolve cwd from /proc
    cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "?")
    cwd=$(echo "$cwd" | sed "s|^$HOME/||; s|^$HOME$|~(home)|")

    # Start time from ps (convert to YYYY/MM/DD HH:MM:SS)
    started=$(date -d "$(ps -p "$pid" -o lstart= 2>/dev/null)" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || echo "-")

    # Extract session ID from --resume arg
    sid=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null \
      | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

    # Resolve topic and last-active from JSONL
    topic="-"
    last_active="-"
    if [ -n "$sid" ]; then
      local jsonl
      jsonl=$(find "$HOME/.claude/projects" -maxdepth 2 -name "${sid}.jsonl" 2>/dev/null | head -1)
      if [ -n "$jsonl" ]; then
        last_active=$(date -d "$(stat -c '%y' "$jsonl")" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || echo "-")
        topic=$(_ccs_topic_from_jsonl "$jsonl")
      fi
    fi

    printf "\033[33m  PID %-8s  %4d MB  %-25s  %s → %s\033[0m\n" "$pid" "$mb" "$cwd" "$started" "$last_active"
    printf "\033[33m  %17s Topic: %s\033[0m\n\n" "" "$topic"
  done < <(ps -eo pid,stat,rss,etime,args | awk '$2 ~ /^T/ && /claude/ && !/awk/')

  if [ ${#pids[@]} -eq 0 ]; then
    echo "No stopped claude processes found."
    return 0
  fi

  printf "Found \033[1m%d\033[0m stopped process(es), total \033[1m%d MB\033[0m RAM\n" "${#pids[@]}" "$total_mb"

  if $dry_run; then
    echo "(dry-run: no processes killed)"
    return 0
  fi

  if ! $force; then
    printf "Kill all %d stopped process(es)? [y/N] " "${#pids[@]}"
    read -r confirm
    case "$confirm" in
      [yY]*) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  echo "Sending SIGTERM..."
  for pid in "${pids[@]}"; do
    kill -CONT "$pid" 2>/dev/null  # resume first so it can handle SIGTERM
    kill -TERM "$pid" 2>/dev/null
  done
  sleep 1

  # Check survivors, SIGKILL if needed
  local survivors=0
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null
      survivors=$((survivors + 1))
    fi
  done

  if [ "$survivors" -gt 0 ]; then
    printf "  %d process(es) needed SIGKILL\n" "$survivors"
  fi
  printf "\033[32mFreed ~%d MB RAM\033[0m\n" "$total_mb"
}

# ── Helper: get system boot time as epoch ──
# Returns epoch via stdout. Returns 1 if unavailable (e.g., containers).
_ccs_get_boot_epoch() {
  local boot_str
  # Primary: uptime -s
  boot_str=$(uptime -s 2>/dev/null)
  if [ -n "$boot_str" ]; then
    date -d "$boot_str" +%s 2>/dev/null && return 0
  fi
  # Fallback: who -b
  boot_str=$(who -b 2>/dev/null | awk '{print $3, $4}')
  if [ -n "$boot_str" ]; then
    date -d "$boot_str" +%s 2>/dev/null && return 0
  fi
  return 1
}

# ── Helper: detect crash-interrupted sessions ──
# Usage: declare -A crash_map; _ccs_detect_crash crash_map [--reboot-window N] [--idle-window N] [files_array] [projects_array]
# crash_map[session_id] = "high:reboot" | "high:non-reboot" | "low:non-reboot"
_ccs_detect_crash() {
  local -n _crash_out=$1; shift
  local reboot_window=30 idle_window=1440

  while [ $# -gt 0 ]; do
    case "$1" in
      --reboot-window) reboot_window="$2"; shift 2 ;;
      --idle-window) idle_window="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  # Remaining args: files_array_name projects_array_name
  # Use a flag to track standalone mode and avoid double nameref
  local _standalone=false
  local -a _standalone_files=() _standalone_projects=() _standalone_rows=()
  if [ $# -ge 2 ]; then
    local -n _cd_files=$1 _cd_projects=$2
  else
    _standalone=true
    _ccs_collect_sessions _standalone_files _standalone_projects _standalone_rows
    local -n _cd_files=_standalone_files _cd_projects=_standalone_projects
  fi

  local now=$(date +%s)
  local boot_epoch
  if ! boot_epoch=$(_ccs_get_boot_epoch); then
    boot_epoch=0
    echo "ccs-crash: warning: cannot determine boot time (container?), Path 1 disabled" >&2
  fi

  local reboot_window_start=0 reboot_upper=0
  if [ "$boot_epoch" -gt 0 ]; then
    reboot_window_start=$((boot_epoch - reboot_window * 60))
    reboot_upper=$((boot_epoch + 120))
  fi

  local idle_window_start=$((now - idle_window * 60))

  # Path 2: get list of running claude session IDs (once)
  local running_sids=""
  running_sids=$(ps -eo args 2>/dev/null | grep -oP '(?<=--resume )[0-9a-f-]{36}' | sort -u)

  local count=${#_cd_files[@]}
  local i
  for ((i = 0; i < count; i++)); do
    local f="${_cd_files[$i]}"
    [ -f "$f" ] || continue

    local mtime sid
    mtime=$(stat -c "%Y" "$f" 2>/dev/null) || continue
    sid=$(basename "$f" .jsonl)

    # Path 1: Reboot detection
    if [ "$boot_epoch" -gt 0 ] && [ "$mtime" -ge "$reboot_window_start" ] && [ "$mtime" -lt "$reboot_upper" ]; then
      _crash_out["$sid"]="high:reboot"
      continue
    fi

    # Path 2: Non-reboot detection
    # Skip if mtime outside idle window or after boot (already running post-reboot)
    [ "$mtime" -ge "$idle_window_start" ] || continue
    [ "$boot_epoch" -eq 0 ] || [ "$mtime" -ge "$reboot_upper" ] || continue

    # Check if process is still running
    echo "$running_sids" | grep -q "$sid" && continue

    # Check for interrupt signals in last assistant message (raw JSONL)
    # Last assistant message: content array with no text entries = mid-execution crash
    local has_text
    has_text=$(tac "$f" 2>/dev/null | grep -m1 '"type":"assistant"' | jq -r '
      if .message.content then
        ([.message.content[] | select(.type == "text" and (.text | length > 0))] | length)
      else
        0
      end
    ' 2>/dev/null)

    if [ "${has_text:-0}" = "0" ]; then
      _crash_out["$sid"]="high:non-reboot"
    else
      _crash_out["$sid"]="low:non-reboot"
    fi
  done
}

# ── Helper: resolve JSONL directory name → actual filesystem path ──
# JSONL dirs encode paths as: $HOME/tools/ccs-dashboard → -home-user-tools-ccs-dashboard
# Simple sed 's/-/\//g' fails when project names contain hyphens.
# Strategy: greedy match — try longest path first, progressively split remaining hyphens.
_ccs_resolve_project_path() {
  local encoded="$1"
  [ -z "$encoded" ] && return 1

  # Special case: home directory
  if [ "$encoded" = "$_CCS_HOME_ENCODED" ]; then
    echo "$HOME"
    return 0
  fi

  # Convert leading dash to slash
  local raw="/${encoded#-}"

  # Try full path as-is (no hyphens in any segment)
  [ -d "$raw" ] && { echo "$raw"; return 0; }

  # Left-to-right greedy: find the longest existing directory prefix,
  # then recurse on the remainder.
  # Split into segments by '-'
  local IFS='-'
  local -a parts=($raw)
  unset IFS

  # Rebuild path greedily: accumulate segments, try extending with '-' first (keep hyphen),
  # then try '/' (split). Prefer longest directory match.
  local resolved=""
  local i=0
  local len=${#parts[@]}

  while [ $i -lt $len ]; do
    # Try extending current segment with hyphen (greedy: keep as many hyphens as possible)
    local candidate="$resolved"
    local best_j=$i
    local j
    for ((j = len; j > i; j--)); do
      # Build candidate from parts[i..j-1] joined with '-'
      local segment="${parts[$i]}"
      local k
      for ((k = i + 1; k < j; k++)); do
        segment="${segment}-${parts[$k]}"
      done
      local try_path
      if [ -z "$resolved" ]; then
        try_path="$segment"
      else
        try_path="${resolved}/${segment}"
      fi
      # Check if this is a valid directory (or final segment)
      if [ -d "$try_path" ]; then
        resolved="$try_path"
        best_j=$j
        break
      fi
    done

    if [ $best_j -eq $i ]; then
      # No match found, just append with /
      if [ -z "$resolved" ]; then
        resolved="${parts[$i]}"
      else
        resolved="${resolved}/${parts[$i]}"
      fi
      i=$((i + 1))
    else
      i=$best_j
    fi
  done

  echo "$resolved"
}
