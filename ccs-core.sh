#!/usr/bin/env bash
# ccs-core.sh — Claude Code Session core helpers and basic commands
# Part of ccs-dashboard. Sourced by ccs-dashboard.sh automatically.
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
  project=$(echo "$dir" | sed 's/^-pool2-chenhsun-*//; s/-/\//g')
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
    topic=$(grep -m1 '"type":"user"' "$f" 2>/dev/null \
      | jq -r '.message.content | if type == "array" then .[0].text else . end' 2>/dev/null \
      | head -1 | tr '\n' ' ')
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
    topic=$(grep -m1 '"type":"user"' "$f" 2>/dev/null \
      | jq -r '.message.content | if type == "array" then .[0].text else . end' 2>/dev/null \
      | head -1 | tr '\n' ' ')
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
