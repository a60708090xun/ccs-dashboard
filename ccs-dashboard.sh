#!/usr/bin/env bash
# ccs-dashboard.sh — Claude Code Session dashboard (personal tool, not official)
# Source this file from .bashrc:  source ~/.local/lib/ccs-dashboard.sh
#
# Commands:
#   ccs-status  (ccs)   — unified dashboard: active + zombies + stale
#   ccs-sessions        — all sessions within N hours
#   ccs-active          — non-archived sessions within N days
#   ccs-cleanup         — kill stopped (suspended) claude processes
#   ccs-handoff         — generate session handoff note

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

# ── ccs-status (ccs) — unified session dashboard ──
ccs-status() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-status (ccs)  — unified session dashboard
[personal tool, not official Claude Code]

Sections:
  1. Active sessions   — open, non-archived (last 7 days, < 1 day old)
  2. Zombie processes  — stopped claude processes eating RAM
  3. Stale sessions    — open but untouched > 1 day

Colors:
  green   active (< 10 min)    yellow  recent (< 1 hour)
  blue    idle (< 1 day)       gray    stale (> 1 day)
HELP
    return 0
  fi

  local projects_dir="$HOME/.claude/projects"

  # ── Section 1: Active sessions ──
  printf "\033[1;36m━━ Active Sessions ━━\033[0m\n"
  local prev_project="" active_count=0
  local open_files=()
  while IFS= read -r -d '' f; do
    tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"' || open_files+=("$f")
  done < <(find "$projects_dir" -maxdepth 2 -name "*.jsonl" -mmin -$((7 * 1440)) ! -path "*/subagents/*" -print0 2>/dev/null)

  # Split into fresh (< 1 day) and stale (>= 1 day)
  local fresh_files=() stale_files=()
  local now
  now=$(date +%s)
  for f in "${open_files[@]}"; do
    local mod ago
    mod=$(stat -c "%Y" "$f")
    ago=$(( (now - mod) / 60 ))
    if [ "$ago" -lt 1440 ]; then
      fresh_files+=("$f")
    else
      stale_files+=("$f")
    fi
  done

  if [ ${#fresh_files[@]} -eq 0 ]; then
    printf "  \033[90m(none)\033[0m\n"
  else
    printf "\033[1m  %-30s %-10s %-10s %s\033[0m\n" "PROJECT" "SESSION" "ACTIVE" "TOPIC"
    for f in "${fresh_files[@]}"; do
      _ccs_session_row "$f"
    done | sort -t$'\t' -k1,1 -k2,2n | while IFS=$'\t' read -r proj _ _ color display; do
      if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
        echo
      fi
      prev_project="$proj"
      printf "  ${color}%s\033[0m\n" "$display"
      active_count=$((active_count + 1))
    done
  fi

  # ── Section 2: Zombie processes ──
  echo
  printf "\033[1;31m━━ Zombie Processes ━━\033[0m\n"
  local zombie_count=0 zombie_mb=0
  while IFS= read -r line; do
    local pid rss mb cwd sid topic started last_active
    pid=$(echo "$line" | awk '{print $1}')
    rss=$(echo "$line" | awk '{print $3}')
    mb=$((rss / 1024))
    zombie_count=$((zombie_count + 1))
    zombie_mb=$((zombie_mb + mb))

    cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "?")
    cwd=$(echo "$cwd" | sed "s|^$HOME/||; s|^$HOME$|~|")

    # Start time from ps (convert to YYYY/MM/DD HH:MM:SS)
    started=$(date -d "$(ps -p "$pid" -o lstart= 2>/dev/null)" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || echo "-")

    # Session ID from cmdline
    sid=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null \
      | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    topic="-"
    last_active="-"
    if [ -n "$sid" ]; then
      local jsonl
      jsonl=$(find "$projects_dir" -maxdepth 2 -name "${sid}.jsonl" 2>/dev/null | head -1)
      if [ -n "$jsonl" ]; then
        last_active=$(date -d "$(stat -c '%y' "$jsonl")" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || echo "-")
        topic=$(_ccs_topic_from_jsonl "$jsonl")
      fi
    fi

    printf "\033[31m  PID %-8s  %4d MB  %-25s  %s → %s\033[0m\n" "$pid" "$mb" "$cwd" "$started" "$last_active"
    printf "\033[31m  %17s Topic: %s\033[0m\n\n" "" "$topic"
  done < <(ps -eo pid,stat,rss,etime,args | awk '$2 ~ /^T/ && /claude/ && !/awk/')

  if [ "$zombie_count" -eq 0 ]; then
    printf "  \033[32m(none)\033[0m\n"
  else
    printf "\n  \033[1m%d zombie(s), %d MB RAM\033[0m → \033[33mccs-cleanup\033[0m to free\n" "$zombie_count" "$zombie_mb"
  fi

  # ── Section 3: Stale sessions ──
  echo
  printf "\033[1;90m━━ Stale Sessions ━━\033[0m\n"
  if [ ${#stale_files[@]} -eq 0 ]; then
    printf "  \033[32m(none)\033[0m\n"
  else
    printf "  \033[90m%d open session(s) untouched > 1 day\033[0m → \033[33mccs-sessions 168\033[0m to inspect\n" "${#stale_files[@]}"
  fi
}
alias ccs='ccs-status'

# ── ccs-handoff [project-dir] — generate session handoff note ──
ccs-handoff() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-handoff [project-dir]  — generate session handoff note (default: current dir)
[personal tool, not official Claude Code]

Output: ~/docs/tmp/handoff/<date>-<topic-slug>.md
HELP
    return 0
  fi

  local project_dir="${1:-.}"
  project_dir=$(cd "$project_dir" && pwd)
  local projects_dir="$HOME/.claude/projects"
  local handoff_dir="$HOME/docs/tmp/handoff"
  mkdir -p "$handoff_dir"

  # Find matching project dir in .claude/projects
  local encoded_dir
  encoded_dir=$(echo "$project_dir" | sed 's|/|-|g')
  local session_dir="$projects_dir/$encoded_dir"

  if [ ! -d "$session_dir" ]; then
    echo "No Claude sessions found for: $project_dir"
    return 1
  fi

  # Collect open (non-archived) sessions from last 7 days, sorted by recency
  local open_sessions=()
  while IFS=$'\t' read -r _ path; do
    open_sessions+=("$path")
  done < <(
    find "$session_dir" -maxdepth 1 -name "*.jsonl" -mmin -10080 ! -path "*/subagents/*" -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"' && continue
        printf '%s\t%s\n' "$(stat -c '%Y' "$f")" "$f"
      done | sort -rn
  )

  if [ ${#open_sessions[@]} -eq 0 ]; then
    echo "No open sessions found for: $project_dir"
    return 1
  fi

  # Extract info from the most recent open session
  local latest="${open_sessions[0]}"
  local sid mod_date topic

  sid=$(basename "$latest" .jsonl | cut -c1-8)
  mod_date=$(stat -c "%y" "$latest" | cut -d. -f1)

  topic=$(_ccs_topic_from_jsonl "$latest")
  [ -z "$topic" ] && topic="(no topic)"

  # Get last 5 human messages (skip: meta, task notifications, XML, cd commands)
  local last_msgs
  last_msgs=$(tac "$latest" 2>/dev/null \
    | jq -r 'select(.type == "user" and (.isMeta | not)) | .message.content | if type == "array" then ([.[] | select(.type == "text") | .text] | first) else . end // empty' 2>/dev/null \
    | grep -av '^\s*$' | grep -av '^<' | grep -av '^!*cd ' \
    | head -5 | tac | while IFS= read -r line; do
        echo "- $(echo "$line" | cut -c1-120)"
      done)

  # Git context
  local git_branch git_status git_log
  git_branch=$(cd "$project_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
  git_status=$(cd "$project_dir" && git status --short 2>/dev/null | head -10)
  git_log=$(cd "$project_dir" && git log --oneline -5 2>/dev/null)

  # All open sessions summary
  local sessions_summary=""
  local zombie_count=0
  for f in "${open_sessions[@]}"; do
    local s_sid s_mod s_ago s_age s_topic
    s_sid=$(basename "$f" .jsonl | cut -c1-8)
    s_mod=$(stat -c "%Y" "$f"); s_ago=$(( ($(date +%s) - s_mod) / 60 ))
    if [ "$s_ago" -lt 60 ]; then s_age="${s_ago}m"
    elif [ "$s_ago" -lt 1440 ]; then s_age="$((s_ago/60))h"
    else s_age="$((s_ago/1440))d"; fi
    s_topic=$(_ccs_topic_from_jsonl "$f")
    # Skip zombies: no topic, or starts with < (system message)
    if [ "$s_topic" = "-" ] || echo "$s_topic" | grep -q '^<'; then
      zombie_count=$((zombie_count + 1))
      continue
    fi
    sessions_summary="${sessions_summary}| ${s_sid} | ${s_age} ago | ${s_topic} |
"
  done
  [ "$zombie_count" -gt 0 ] && sessions_summary="${sessions_summary}
*+ ${zombie_count} zombie sessions (no topic/system-only)*
"

  # Generate slug for filename
  local slug
  slug=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
  [ -z "$slug" ] && slug="handoff"
  local handoff_file="$handoff_dir/$(date '+%Y-%m-%d')-${slug}.md"

  cat > "$handoff_file" << EOF
# 交接：${topic}

> Auto-generated by \`ccs-handoff\` — $(date '+%Y-%m-%d %H:%M')
> Project: \`${project_dir}\`

## Open Sessions

| Session ID | Last Active | Topic |
|------------|-------------|-------|
${sessions_summary}
## 最近 Session 的對話脈絡

**Session:** ${sid} | **Branch:** ${git_branch} | **Last Active:** ${mod_date}

${last_msgs}

## Git 狀態

\`\`\`
Branch: ${git_branch}

Recent commits:
${git_log:-"(no commits)"}

Uncommitted:
${git_status:-"(clean)"}
\`\`\`

## 目前進度

<!-- 自動產生的骨架，請在結束 session 前補充 -->
-

## 下一步

<!-- 下一個 session 應該做什麼 -->
-

## 重要決策

<!-- 這個 session 做了哪些決策，為什麼 -->
-
EOF

  echo "Created: $handoff_file"
  echo ""
  echo "  Topic:    ${topic}"
  echo "  Sessions: ${#open_sessions[@]} open"
  echo "  Branch:   ${git_branch}"
  echo ""
  echo "Edit the file to fill in: 目前進度 / 下一步 / 重要決策"
}
