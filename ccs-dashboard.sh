#!/usr/bin/env bash
# ccs-dashboard.sh — Claude Code Session dashboard (personal tool, not official)
# Source this file from .bashrc:  source ~/tools/ccs-dashboard/ccs-dashboard.sh
#
# Commands:
#   ccs-status  (ccs)   — unified dashboard: active + zombies + stale
#   ccs-sessions        — all sessions within N hours
#   ccs-active          — non-archived sessions within N days
#   ccs-cleanup         — kill stopped (suspended) claude processes
#   ccs-details         — interactive session conversation browser
#   ccs-pick N          — show details for Nth session from --md list
#   ccs-html            — generate HTML dashboard
#   ccs-handoff         — generate session handoff note
#   ccs-resume-prompt   — generate bootstrap prompt for new session

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

Options:
  --md [--list|--table]   Output as Markdown (for Happy web / Claude Code rendering)
                          --list  list format, mobile-friendly (default)
                          --table table format

Colors (terminal):
  green   active (< 10 min)    yellow  recent (< 1 hour)
  blue    idle (< 1 day)       gray    stale (> 1 day)
HELP
    return 0
  fi

  local md=false md_fmt="list"
  while [ $# -gt 0 ]; do
    case "$1" in
      --md) md=true; shift ;;
      --list) md_fmt="list"; shift ;;
      --table) md_fmt="table"; shift ;;
      *) shift ;;
    esac
  done

  local projects_dir="$HOME/.claude/projects"

  # ── Collect data (shared by both modes) ──
  local open_files=()
  while IFS= read -r -d '' f; do
    tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"' || open_files+=("$f")
  done < <(find "$projects_dir" -maxdepth 2 -name "*.jsonl" -mmin -$((7 * 1440)) ! -path "*/subagents/*" -print0 2>/dev/null)

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

  # ── Markdown mode ──
  if $md; then
    _ccs_status_md "$md_fmt" "$now" "${fresh_files[@]}" "---" "${stale_files[@]}"
    return 0
  fi

  # ── Terminal mode (ANSI) ──
  printf "\033[1;36m━━ Active Sessions ━━\033[0m\n"
  local prev_project="" active_count=0

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

    started=$(date -d "$(ps -p "$pid" -o lstart= 2>/dev/null)" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || echo "-")

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

  echo
  printf "\033[1;90m━━ Stale Sessions ━━\033[0m\n"
  if [ ${#stale_files[@]} -eq 0 ]; then
    printf "  \033[32m(none)\033[0m\n"
  else
    printf "  \033[90m%d open session(s) untouched > 1 day\033[0m → \033[33mccs-sessions 168\033[0m to inspect\n" "${#stale_files[@]}"
  fi
}

# ── Helper: markdown output for ccs-status --md ──
# Usage: _ccs_status_md <list|table> <now> <fresh_files...> --- <stale_files...>
_ccs_status_md() {
  local fmt="$1"; shift
  local now="$1"; shift
  local projects_dir="$HOME/.claude/projects"

  # Split args by "---" separator into fresh_files and stale_files
  local fresh_files=() stale_files=() past_sep=false
  for arg in "$@"; do
    if [ "$arg" = "---" ]; then past_sep=true; continue; fi
    if $past_sep; then stale_files+=("$arg"); else fresh_files+=("$arg"); fi
  done

  echo "### ⚡ Active Sessions"
  echo

  if [ ${#fresh_files[@]} -eq 0 ]; then
    echo "_(none)_"
  else
    # Sort by project, then by age
    local sorted_rows
    sorted_rows=$(for f in "${fresh_files[@]}"; do
      local mod ago project dir
      mod=$(stat -c "%Y" "$f")
      ago=$(( (now - mod) / 60 ))
      dir=$(basename "$(dirname "$f")")
      project=$(echo "$dir" | sed 's/^-pool2-chenhsun-*//; s/-/\//g')
      [ -z "$project" ] && project="~(home)"
      printf '%s\t%d\t%s\n' "$project" "$ago" "$f"
    done | sort -t$'\t' -k1,1 -k2,2n)

    # Table header (table mode only)
    if [ "$fmt" = "table" ]; then
      echo "| # | Project | Session | Active | Status | Topic |"
      echo "|---|---------|---------|--------|--------|-------|"
    fi

    local prev_project="" session_idx=0
    # Also build index file for ccs-pick
    local pick_file="$HOME/.claude/.ccs-pick-index"
    : > "$pick_file"

    while IFS=$'\t' read -r project ago f; do
      local ago_str icon sid topic full_sid
      session_idx=$((session_idx + 1))

      full_sid=$(basename "$f" .jsonl)
      sid=$(echo "$full_sid" | cut -c1-8)
      topic=$(_ccs_topic_from_jsonl "$f")

      if [ "$ago" -lt 10 ]; then
        icon="🟢"; ago_str="${ago}m ago"
      elif [ "$ago" -lt 60 ]; then
        icon="🟡"; ago_str="${ago}m ago"
      else
        icon="🔵"; ago_str="$((ago / 60))h ago"
      fi

      # Write to pick index: idx \t sid_prefix \t topic
      printf '%d\t%s\t%s\n' "$session_idx" "$sid" "$topic" >> "$pick_file"

      if [ "$fmt" = "table" ]; then
        local status_label
        if [ "$ago" -lt 10 ]; then status_label="active"
        elif [ "$ago" -lt 60 ]; then status_label="recent"
        else status_label="idle"; fi
        topic=$(echo "$topic" | sed 's/|/\\|/g')
        project=$(echo "$project" | sed 's/|/\\|/g')
        echo "| ${session_idx} | ${project} | \`${sid}\` | ${ago_str} | ${icon} ${status_label} | ${topic} |"
      else
        # List mode — group by project with header + hr
        if [ "$project" != "$prev_project" ]; then
          [ -n "$prev_project" ] && echo "---"
          local proj_count
          proj_count=$(echo "$sorted_rows" | grep -c "^${project}	")
          echo "📁 **${project}** (${proj_count})"
          echo
        fi
        prev_project="$project"
        echo "${icon} **${session_idx}.** **${topic}** \`${sid}\` ${ago_str}"
        echo
      fi
    done <<< "$sorted_rows"
  fi

  # Zombie processes
  echo "### 🧟 Zombie Processes"
  echo

  local zombie_count=0 zombie_mb=0 has_zombie=false
  while IFS= read -r line; do
    has_zombie=true
    local pid rss mb cwd sid topic started
    pid=$(echo "$line" | awk '{print $1}')
    rss=$(echo "$line" | awk '{print $3}')
    mb=$((rss / 1024))
    zombie_count=$((zombie_count + 1))
    zombie_mb=$((zombie_mb + mb))

    cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "?")
    cwd=$(echo "$cwd" | sed "s|^$HOME/||; s|^$HOME$|~|")

    started=$(date -d "$(ps -p "$pid" -o lstart= 2>/dev/null)" '+%m/%d %H:%M' 2>/dev/null || echo "-")

    sid=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null \
      | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    topic="-"
    if [ -n "$sid" ]; then
      local jsonl
      jsonl=$(find "$projects_dir" -maxdepth 2 -name "${sid}.jsonl" 2>/dev/null | head -1)
      [ -n "$jsonl" ] && topic=$(_ccs_topic_from_jsonl "$jsonl")
    fi

    if [ "$fmt" = "table" ]; then
      if [ "$zombie_count" -eq 1 ]; then
        echo "| PID | RAM | Working Dir | Started | Topic |"
        echo "|-----|-----|-------------|---------|-------|"
      fi
      topic=$(echo "$topic" | sed 's/|/\\|/g')
      cwd=$(echo "$cwd" | sed 's/|/\\|/g')
      echo "| ${pid} | ${mb} MB | ${cwd} | ${started} | ${topic} |"
    else
      echo "🔴 PID ${pid} · ${mb} MB · ${cwd} · ${started}"
      echo "> ${topic}"
      echo
    fi
  done < <(ps -eo pid,stat,rss,etime,args | awk '$2 ~ /^T/ && /claude/ && !/awk/')

  if ! $has_zombie; then
    echo "_(none)_ ✓"
  else
    echo
    echo "> **${zombie_count}** zombie(s), **${zombie_mb} MB** RAM → \`ccs-cleanup\` to free"
  fi

  # Stale sessions
  echo
  echo "### 💤 Stale Sessions"
  echo
  if [ ${#stale_files[@]} -eq 0 ]; then
    echo "_(none)_ ✓"
  else
    echo "> **${#stale_files[@]}** open session(s) untouched > 1 day → \`ccs-sessions 168\` to inspect"
  fi

  # Pick hint
  echo
  echo "---"
  echo "_Reply with a number to see session details → \`ccs-pick N\`_"
}
alias ccs='ccs-status'

# ── ccs-pick <N> — show details for Nth session from ccs-status --md ──
ccs-pick() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-pick <N> [-n COUNT]  — show details for the Nth session from ccs-status --md
[personal tool, not official Claude Code]

Uses the index built by the last ccs-status --md run.
Run ccs-status --md first to build the index.

Options:
  --md        Output as Markdown (for Happy web rendering)
  -n COUNT    Number of prompt-response pairs to show (default: 3)
HELP
    return 0
  fi

  local pick_file="$HOME/.claude/.ccs-pick-index"
  local idx="" md=false pair_count=3 full_pair=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --md) md=true; shift ;;
      -n) pair_count="$2"; shift 2 ;;
      --full) full_pair="$2"; shift 2 ;;
      *) idx="$1"; shift ;;
    esac
  done

  # --full N:P mode — extract idx and pair number
  if [ -n "$full_pair" ]; then
    idx="${full_pair%%:*}"
    local full_p="${full_pair##*:}"
  fi

  if [ -z "$idx" ]; then
    echo "Usage: ccs-pick <N>"
    return 1
  fi

  if [ ! -f "$pick_file" ]; then
    echo "No index found. Run ccs-status --md first."
    return 1
  fi

  local sid topic
  sid=$(awk -F'\t' -v n="$idx" '$1 == n {print $2}' "$pick_file")
  topic=$(awk -F'\t' -v n="$idx" '$1 == n {print $3}' "$pick_file")

  if [ -z "$sid" ]; then
    local total
    total=$(wc -l < "$pick_file")
    echo "Invalid index: ${idx} (valid: 1-${total})"
    return 1
  fi

  if $md; then
    # Markdown output for Happy web
    local jsonl
    jsonl=$(_ccs_resolve_jsonl "$sid" "true")
    if [ -z "$jsonl" ]; then
      echo "Session not found: ${sid}"
      return 1
    fi

    local full_sid mod_date dir project status
    full_sid=$(basename "$jsonl" .jsonl)
    mod_date=$(stat -c "%y" "$jsonl" | cut -d. -f1)
    dir=$(basename "$(dirname "$jsonl")")
    project=$(echo "$dir" | sed 's/^-pool2-chenhsun-*//; s/-/\//g')
    [ -z "$project" ] && project="~(home)"

    if tail -20 "$jsonl" 2>/dev/null | grep -q '"type":"last-prompt"'; then
      status="archived"
    else
      local now ago
      now=$(date +%s); ago=$(( (now - $(stat -c "%Y" "$jsonl")) / 60 ))
      if [ "$ago" -lt 10 ]; then status="active"
      elif [ "$ago" -lt 60 ]; then status="recent"
      elif [ "$ago" -lt 1440 ]; then status="idle"
      else status="stale"; fi
    fi

    local total_prompts
    total_prompts=$(jq -c 'select(.type == "user" and (.message.content | type == "string"))' "$jsonl" 2>/dev/null | wc -l)

    echo "### 🔍 #${idx} ${topic}"
    echo
    echo "> **Session:** \`${sid}\` (${status}) · **Project:** ${project} · **Prompts:** ${total_prompts} · **Last:** ${mod_date}"

    # --full mode: show single pair untruncated
    if [ -n "$full_pair" ]; then
      local pair_json user_text assistant_text
      pair_json=$(_ccs_get_pair "$jsonl" "$full_p")
      user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
      assistant_text=$(echo "$pair_json" | tail -1 | jq -r '.text' 2>/dev/null)

      echo
      echo "---"
      echo "#### 💬 Prompt [${full_p}/${total_prompts}]"
      echo
      echo "${user_text}"
      echo
      echo "#### 🤖 Response (full)"
      echo
      echo "${assistant_text}"
      echo
      echo "---"
      echo "_Resume: \`claude --resume ${full_sid}\`_"
      return 0
    fi

    # Show last N prompt-response pairs (oldest first)
    local start_from=$((total_prompts - pair_count + 1))
    [ "$start_from" -lt 1 ] && start_from=1
    local p
    for ((p = start_from; p <= total_prompts; p++)); do
      local pair_json user_text assistant_text
      pair_json=$(_ccs_get_pair "$jsonl" "$p")
      user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
      assistant_text=$(echo "$pair_json" | tail -1 | jq -r '.text' 2>/dev/null)

      echo
      echo "---"
      echo "#### 💬 Prompt [${p}/${total_prompts}]"
      echo
      echo "${user_text}"
      echo
      echo "#### 🤖 Response"
      echo
      local max_resp_lines=10
      echo "${assistant_text}" | head -"$max_resp_lines"
      local total_lines
      total_lines=$(echo "$assistant_text" | wc -l)
      if [ "$total_lines" -gt "$max_resp_lines" ]; then
        echo
        echo "_... (+$((total_lines - max_resp_lines)) lines) → \`ccs-pick --md --full ${idx}:${p}\`_"
      fi
    done
    echo
    echo "---"
    echo "_Resume: \`claude --resume ${full_sid}\`_"
  else
    ccs-details --last "$sid"
  fi
}

# ── ccs-html [--open] — generate HTML dashboard ──
ccs-html() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-html [--open]  — generate HTML session dashboard
[personal tool, not official Claude Code]

Generates a standalone HTML file with session status.
Output: ~/tools/ccs-dashboard/dashboard.html

  --open    Open in default browser after generating
HELP
    return 0
  fi

  local open_browser=false
  [ "$1" = "--open" ] && open_browser=true

  local projects_dir="$HOME/.claude/projects"
  local html_file="$HOME/tools/ccs-dashboard/dashboard.html"
  local now
  now=$(date +%s)
  local gen_time
  gen_time=$(date '+%Y-%m-%d %H:%M:%S')

  # ── Collect session data ──
  local open_files=()
  while IFS= read -r -d '' f; do
    tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"' || open_files+=("$f")
  done < <(find "$projects_dir" -maxdepth 2 -name "*.jsonl" -mmin -$((7 * 1440)) ! -path "*/subagents/*" -print0 2>/dev/null)

  # Split fresh / stale
  local fresh_rows="" stale_count=0
  local zombie_rows="" zombie_count=0 zombie_mb=0

  for f in "${open_files[@]}"; do
    local mod ago ago_str status status_class project sid topic full_sid
    mod=$(stat -c "%Y" "$f")
    ago=$(( (now - mod) / 60 ))

    full_sid=$(basename "$f" .jsonl)
    sid=$(echo "$full_sid" | cut -c1-8)

    local dir
    dir=$(basename "$(dirname "$f")")
    project=$(echo "$dir" | sed 's/^-pool2-chenhsun-*//; s/-/\//g')
    [ -z "$project" ] && project="~(home)"

    topic=$(_ccs_topic_from_jsonl "$f")

    if [ "$ago" -lt 10 ]; then
      status="active"; status_class="active"
      ago_str="${ago}m ago"
    elif [ "$ago" -lt 60 ]; then
      status="recent"; status_class="recent"
      ago_str="${ago}m ago"
    elif [ "$ago" -lt 1440 ]; then
      status="idle"; status_class="idle"
      ago_str="$((ago / 60))h ago"
    else
      stale_count=$((stale_count + 1))
      continue
    fi

    # Escape HTML
    topic=$(echo "$topic" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    project=$(echo "$project" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    fresh_rows="${fresh_rows}<tr class=\"${status_class}\">
  <td>${project}</td>
  <td><code>${sid}</code></td>
  <td>${ago_str}</td>
  <td><span class=\"badge ${status_class}\">${status}</span></td>
  <td>${topic}</td>
</tr>
"
  done

  # ── Zombie processes ──
  while IFS= read -r line; do
    local pid rss mb cwd sid topic started last_active
    pid=$(echo "$line" | awk '{print $1}')
    rss=$(echo "$line" | awk '{print $3}')
    mb=$((rss / 1024))
    zombie_count=$((zombie_count + 1))
    zombie_mb=$((zombie_mb + mb))

    cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "?")
    cwd=$(echo "$cwd" | sed "s|^$HOME/||; s|^$HOME$|~|")

    started=$(date -d "$(ps -p "$pid" -o lstart= 2>/dev/null)" '+%Y/%m/%d %H:%M' 2>/dev/null || echo "-")

    sid=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null \
      | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    topic="-"
    if [ -n "$sid" ]; then
      local jsonl
      jsonl=$(find "$projects_dir" -maxdepth 2 -name "${sid}.jsonl" 2>/dev/null | head -1)
      [ -n "$jsonl" ] && topic=$(_ccs_topic_from_jsonl "$jsonl")
    fi

    topic=$(echo "$topic" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    cwd=$(echo "$cwd" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    zombie_rows="${zombie_rows}<tr>
  <td>${pid}</td>
  <td>${mb} MB</td>
  <td>${cwd}</td>
  <td>${started}</td>
  <td>${topic}</td>
</tr>
"
  done < <(ps -eo pid,stat,rss,etime,args | awk '$2 ~ /^T/ && /claude/ && !/awk/')

  # ── Generate HTML ──
  cat > "$html_file" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CCS Dashboard</title>
<style>
  :root {
    --bg: #0d1117; --fg: #c9d1d9; --border: #30363d;
    --green: #3fb950; --yellow: #d29922; --blue: #58a6ff;
    --red: #f85149; --gray: #8b949e; --cyan: #39c5cf;
    --card-bg: #161b22;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--fg);
    padding: 24px; line-height: 1.5;
  }
  h1 { color: var(--cyan); margin-bottom: 4px; font-size: 1.4em; }
  .meta { color: var(--gray); font-size: 0.85em; margin-bottom: 20px; }
  .section {
    background: var(--card-bg); border: 1px solid var(--border);
    border-radius: 8px; padding: 16px; margin-bottom: 16px;
  }
  .section h2 {
    font-size: 1em; margin-bottom: 12px; display: flex; align-items: center; gap: 8px;
  }
  .section h2 .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
  .dot-green { background: var(--green); }
  .dot-red { background: var(--red); }
  .dot-gray { background: var(--gray); }
  table { width: 100%; border-collapse: collapse; font-size: 0.9em; }
  th { text-align: left; color: var(--gray); font-weight: 600; padding: 6px 10px;
       border-bottom: 1px solid var(--border); }
  td { padding: 6px 10px; border-bottom: 1px solid var(--border); }
  tr:last-child td { border-bottom: none; }
  code { background: #1c2128; padding: 2px 6px; border-radius: 4px; font-size: 0.85em; }
  .badge {
    display: inline-block; padding: 1px 8px; border-radius: 10px;
    font-size: 0.8em; font-weight: 500;
  }
  .badge.active { background: rgba(63,185,80,0.15); color: var(--green); }
  .badge.recent { background: rgba(210,153,34,0.15); color: var(--yellow); }
  .badge.idle   { background: rgba(88,166,255,0.15); color: var(--blue); }
  .empty { color: var(--gray); font-style: italic; padding: 8px 0; }
  .summary { color: var(--gray); font-size: 0.85em; margin-top: 8px; }
  tr.active td:first-child { border-left: 3px solid var(--green); }
  tr.recent td:first-child { border-left: 3px solid var(--yellow); }
  tr.idle td:first-child   { border-left: 3px solid var(--blue); }
</style>
</head>
<body>
<h1>⚡ CCS Dashboard</h1>
HTMLHEAD

  # Inject dynamic meta
  printf '<p class="meta">Generated: %s</p>\n' "$gen_time" >> "$html_file"

  # Active sessions section
  cat >> "$html_file" << 'SECTION1'
<div class="section">
<h2><span class="dot dot-green"></span> Active Sessions</h2>
SECTION1

  if [ -z "$fresh_rows" ]; then
    echo '<p class="empty">(none)</p>' >> "$html_file"
  else
    cat >> "$html_file" << 'TABLE'
<table>
<tr><th>Project</th><th>Session</th><th>Last Active</th><th>Status</th><th>Topic</th></tr>
TABLE
    printf '%s' "$fresh_rows" >> "$html_file"
    echo '</table>' >> "$html_file"
  fi
  echo '</div>' >> "$html_file"

  # Zombie section
  cat >> "$html_file" << 'SECTION2'
<div class="section">
<h2><span class="dot dot-red"></span> Zombie Processes</h2>
SECTION2

  if [ "$zombie_count" -eq 0 ]; then
    echo '<p class="empty">(none) ✓</p>' >> "$html_file"
  else
    cat >> "$html_file" << 'TABLE2'
<table>
<tr><th>PID</th><th>RAM</th><th>Working Dir</th><th>Started</th><th>Topic</th></tr>
TABLE2
    printf '%s' "$zombie_rows" >> "$html_file"
    echo '</table>' >> "$html_file"
    printf '<p class="summary">%d zombie(s), %d MB RAM → <code>ccs-cleanup</code> to free</p>\n' "$zombie_count" "$zombie_mb" >> "$html_file"
  fi
  echo '</div>' >> "$html_file"

  # Stale section
  cat >> "$html_file" << 'SECTION3'
<div class="section">
<h2><span class="dot dot-gray"></span> Stale Sessions</h2>
SECTION3

  if [ "$stale_count" -eq 0 ]; then
    echo '<p class="empty">(none) ✓</p>' >> "$html_file"
  else
    printf '<p class="summary">%d open session(s) untouched &gt; 1 day → <code>ccs-sessions 168</code> to inspect</p>\n' "$stale_count" >> "$html_file"
  fi
  echo '</div>' >> "$html_file"

  echo '</body></html>' >> "$html_file"

  echo "Generated: $html_file"
  local file_size
  file_size=$(stat -c "%s" "$html_file")
  echo "  Size: ${file_size} bytes"

  if $open_browser; then
    xdg-open "$html_file" 2>/dev/null || open "$html_file" 2>/dev/null || echo "  (could not open browser)"
  fi
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
_ccs_get_pair() {
  local jsonl="$1" pair_idx="$2"

  # Filter: user prompts (string content) and assistant turns with non-empty text
  # Then find the Nth user prompt and its following assistant response
  jq -c '
    if .type == "user" and (.message.content | type == "string") then
      {role: "user", text: .message.content}
    elif .type == "assistant" then
      (.message.content | if type == "array" then
        [.[] | select(.type == "text") | .text] | join("\n")
      else . end) as $t |
      if ($t | length) > 0 then {role: "assistant", text: $t}
      else empty end
    else empty end
  ' "$jsonl" 2>/dev/null \
    | awk -v idx="$pair_idx" 'BEGIN{pn=0;fp=0} /\"role\":\"user\"/{pn++;if(pn==idx){fp=1;print;next}} fp&&/\"role\":\"assistant\"/{print;exit}'
}

# ── ccs-details [session-id-prefix] — interactive session conversation browser ──
ccs-details() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-details [session-id-prefix]  — interactive session conversation browser
[personal tool, not official Claude Code]

Browse prompt-response pairs in a session, similar to tig for git.

Arguments:
  session-id-prefix   First N chars of session UUID (from ccs-active/ccs-sessions)
                      If omitted, uses the most recent session in current project dir.

Options:
  -a, --all           Search all projects (not just current dir)
  --last              Non-interactive: show only the last prompt & response

Interactive keys:
  ↑/↓, j/k           Navigate prompts
  Enter               View full prompt & response (piped to less)
  q, Esc              Quit
HELP
    return 0
  fi

  local prefix="" search_all=false last_only=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--all) search_all=true; shift ;;
      --last) last_only=true; shift ;;
      *) prefix="$1"; shift ;;
    esac
  done

  local jsonl
  jsonl=$(_ccs_resolve_jsonl "$prefix" "$search_all")
  if [ -z "$jsonl" ]; then
    if [ -n "$prefix" ]; then
      echo "No session found matching: ${prefix}*"
    else
      echo "No sessions for current dir. Use -a to search all, or provide a session ID prefix."
    fi
    return 1
  fi

  # ── Session metadata ──
  local full_sid sid mod_date topic status dir project
  full_sid=$(basename "$jsonl" .jsonl)
  sid=$(echo "$full_sid" | cut -c1-8)
  mod_date=$(stat -c "%y" "$jsonl" | cut -d. -f1)

  dir=$(basename "$(dirname "$jsonl")")
  project=$(echo "$dir" | sed 's/^-pool2-chenhsun-*//; s/-/\//g')
  [ -z "$project" ] && project="~(home)"
  topic=$(_ccs_topic_from_jsonl "$jsonl")

  if tail -20 "$jsonl" 2>/dev/null | grep -q '"type":"last-prompt"'; then
    status="archived"
  else
    local now ago
    now=$(date +%s); ago=$(( (now - $(stat -c "%Y" "$jsonl")) / 60 ))
    if [ "$ago" -lt 10 ]; then status="active"
    elif [ "$ago" -lt 60 ]; then status="recent"
    elif [ "$ago" -lt 1440 ]; then status="idle"
    else status="stale"; fi
  fi

  # ── Build pairs index (cached in temp file for performance) ──
  local index_file
  index_file=$(mktemp /tmp/ccs-details-XXXXXX)
  # Each line: sequential_num \t prompt_preview
  jq -r 'select(.type == "user" and (.message.content | type == "string")) | .message.content | split("\n") | join(" ") | .[:100]' "$jsonl" 2>/dev/null > "$index_file"

  local total_prompts
  total_prompts=$(wc -l < "$index_file")

  if [ "$total_prompts" -eq 0 ]; then
    echo "No user prompts found in session."
    rm -f "$index_file"
    return 1
  fi

  # ── --last mode: non-interactive ──
  if $last_only; then
    printf "\033[1;36m━━ Session Details ━━\033[0m\n"
    printf "  \033[1mSession:\033[0m  %s (%s)  \033[1mProject:\033[0m %s\n" "$sid" "$status" "$project"
    printf "  \033[1mTopic:\033[0m    %s  \033[1mLast:\033[0m %s\n" "$topic" "$mod_date"
    printf "  \033[1mPrompts:\033[0m  %d\n" "$total_prompts"

    local pair_json
    pair_json=$(_ccs_get_pair "$jsonl" "$total_prompts")
    local user_text assistant_text
    user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
    assistant_text=$(echo "$pair_json" | tail -1 | jq -r '.text' 2>/dev/null)

    echo
    printf "\033[1;33m━━ Last Prompt [%d/%d] ━━\033[0m\n" "$total_prompts" "$total_prompts"
    printf "\033[33m%s\033[0m\n" "$user_text"
    echo
    printf "\033[1;32m━━ Response ━━\033[0m\n"
    echo "$assistant_text" | head -30
    echo
    printf "\033[90mResume: claude --resume %s\033[0m\n" "$full_sid"
    rm -f "$index_file"
    return 0
  fi

  # ── Interactive mode ──
  local sel=$total_prompts  # start at most recent
  local term_lines key running=true

  # Read index lines into array
  local -a prompts=()
  mapfile -t prompts < "$index_file"
  rm -f "$index_file"

  while $running; do
    term_lines=$(tput lines 2>/dev/null || echo 24)
    local visible=$((term_lines - 8))  # header takes ~6 lines + footer
    [ "$visible" -lt 5 ] && visible=5

    # Clear screen and draw
    clear
    printf "\033[1;36m━━ %s ━━\033[0m  \033[90m%s | %s | %d prompts\033[0m\n" "$topic" "$sid" "$status" "$total_prompts"
    printf "\033[90m  ↑↓/jk navigate  Enter view  q quit\033[0m\n"
    printf '%.0s─' {1..80}; echo

    # Calculate window: show prompts around selection
    local win_start win_end
    win_start=$((sel - visible / 2))
    [ "$win_start" -lt 1 ] && win_start=1
    win_end=$((win_start + visible - 1))
    [ "$win_end" -gt "$total_prompts" ] && win_end=$total_prompts
    # Adjust start if end hit the limit
    win_start=$((win_end - visible + 1))
    [ "$win_start" -lt 1 ] && win_start=1

    local i
    for ((i = win_start; i <= win_end; i++)); do
      local prompt_text="${prompts[$((i-1))]}"
      local display_num
      display_num=$(printf '%3d' "$i")
      if [ "$i" -eq "$sel" ]; then
        printf "\033[7m  %s  %s\033[0m\n" "$display_num" "$prompt_text"
      else
        printf "  \033[90m%s\033[0m  %s\n" "$display_num" "$prompt_text"
      fi
    done

    # Footer
    printf '%.0s─' {1..80}; echo
    printf "\033[90m[%d/%d]\033[0m" "$sel" "$total_prompts"

    # Read key
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')  # escape sequence
        read -rsn2 -t 0.1 key
        case "$key" in
          '[A') [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;           # up
          '[B') [ "$sel" -lt "$total_prompts" ] && sel=$((sel + 1)) ;;  # down
          '') running=false ;;  # bare Esc
        esac
        ;;
      k) [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;
      j) [ "$sel" -lt "$total_prompts" ] && sel=$((sel + 1)) ;;
      g) sel=1 ;;                    # go to first
      G) sel=$total_prompts ;;       # go to last
      q) running=false ;;
      '')  # Enter: show full pair
        local pair_json user_text assistant_text
        pair_json=$(_ccs_get_pair "$jsonl" "$sel")
        user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
        assistant_text=$(echo "$pair_json" | tail -n +2 | jq -r '.text' 2>/dev/null)
        {
          printf "\033[1;33m━━ Prompt [%d/%d] ━━\033[0m\n" "$sel" "$total_prompts"
          printf "\033[33m%s\033[0m\n" "$user_text"
          echo
          printf "\033[1;32m━━ Response ━━\033[0m\n"
          echo "$assistant_text"
        } | less -R
        ;;
    esac
  done

  clear
  printf "\033[90mResume: claude --resume %s\033[0m\n" "$full_sid"
}

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

# ── ccs-resume-prompt [session-id-prefix] — generate bootstrap prompt for new session ──
ccs-resume-prompt() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-resume-prompt [session-id-prefix]  — generate bootstrap prompt for new session
[personal tool, not official Claude Code]

Generates a concise bootstrap prompt (< 2000 tokens) from an existing session,
designed to paste into a fresh Claude Code session for seamless handoff.

Arguments:
  session-id-prefix   First N chars of session UUID (from ccs-active/ccs-sessions)
                      If omitted, uses the most recent session in current project dir.

Options:
  -a, --all           Search all projects (not just current dir)
  -n COUNT            Number of recent prompt-response pairs to summarize (default: 3)
  --copy              Copy to clipboard (xclip)
  --stdout            Print raw prompt only (no header/footer, for piping)
HELP
    return 0
  fi

  local prefix="" search_all=false pair_count=3 do_copy=false raw=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--all) search_all=true; shift ;;
      -n) pair_count="$2"; shift 2 ;;
      --copy) do_copy=true; shift ;;
      --stdout) raw=true; shift ;;
      *) prefix="$1"; shift ;;
    esac
  done

  local jsonl
  jsonl=$(_ccs_resolve_jsonl "$prefix" "$search_all")
  if [ -z "$jsonl" ]; then
    if [ -n "$prefix" ]; then
      echo "No session found matching: ${prefix}*" >&2
    else
      echo "No sessions for current dir. Use -a to search all, or provide a session ID prefix." >&2
    fi
    return 1
  fi

  # ── Session metadata ──
  local full_sid sid topic dir project project_dir
  full_sid=$(basename "$jsonl" .jsonl)
  sid=$(echo "$full_sid" | cut -c1-8)
  topic=$(_ccs_topic_from_jsonl "$jsonl")

  dir=$(basename "$(dirname "$jsonl")")
  project=$(echo "$dir" | sed 's/^-pool2-chenhsun-*//; s/-/\//g')
  [ -z "$project" ] && project="~(home)"
  # Reconstruct project_dir from encoded dir name
  project_dir=$(echo "$dir" | sed 's/-/\//g')
  [ ! -d "$project_dir" ] && project_dir=""

  # ── Git context (if project dir exists) ──
  local git_branch="" git_status="" git_log=""
  if [ -n "$project_dir" ] && [ -d "$project_dir/.git" ]; then
    git_branch=$(cd "$project_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
    git_status=$(cd "$project_dir" && git status --short 2>/dev/null | head -5)
    git_log=$(cd "$project_dir" && git log --oneline -3 2>/dev/null)
  fi

  # ── Extract recent conversation pairs ──
  # Count only real user prompts (skip meta/system messages)
  # Build filtered pair indices: map real prompt index → raw prompt index
  local -a real_to_raw=()
  local raw_idx=0
  while IFS=$'\t' read -r is_meta content; do
    raw_idx=$((raw_idx + 1))
    # Skip meta messages (isMeta flag from Claude)
    [ "$is_meta" = "true" ] && continue
    # Skip system/command wrapper messages
    case "$content" in
      '<local-command'*|'<command-name'*|'<system-'*) continue ;;
    esac
    # Skip /exit, /quit, empty
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

  local conversation_summary=""
  local ri
  for ((ri = start_from; ri <= real_count; ri++)); do
    local raw_p=${real_to_raw[$((ri - 1))]}
    local pair_json user_text assistant_text user_preview assistant_preview
    pair_json=$(_ccs_get_pair "$jsonl" "$raw_p")
    user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
    assistant_text=$(echo "$pair_json" | tail -1 | jq -r '.text' 2>/dev/null)

    # Truncate for token efficiency
    user_preview=$(echo "$user_text" | head -3 | cut -c1-200)
    local user_lines
    user_lines=$(echo "$user_text" | wc -l)
    [ "$user_lines" -gt 3 ] && user_preview="${user_preview}..."

    assistant_preview=$(echo "$assistant_text" | head -5 | cut -c1-200)
    local asst_lines
    asst_lines=$(echo "$assistant_text" | wc -l)
    [ "$asst_lines" -gt 5 ] && assistant_preview="${assistant_preview}..."

    conversation_summary="${conversation_summary}
### [${ri}/${real_count}] User
${user_preview}

### [${ri}/${real_count}] Claude
${assistant_preview}
"
  done

  # ── Extract tool usage from last assistant turn ──
  local recent_files=""
  recent_files=$(jq -r '
    select(.type == "assistant") |
    .message.content[]? |
    select(.type == "tool_use") |
    if .name == "Read" then "R " + .input.file_path
    elif .name == "Edit" then "E " + .input.file_path
    elif .name == "Write" then "W " + .input.file_path
    elif .name == "Bash" then "$ " + (.input.command | split("\n") | first | .[:80])
    else empty end
  ' "$jsonl" 2>/dev/null | tail -10 | sort -u)

  # ── Build the prompt ──
  local prompt=""
  read -r -d '' prompt << PROMPT_EOF
繼續上一個 session 的工作：**${topic}**

## Context

- **Project:** ${project}
- **Session:** \`${sid}\` (${real_count} prompts)$(
[ -n "$git_branch" ] && printf '\n- **Branch:** `%s`' "$git_branch"
)$(
[ -n "$git_log" ] && printf '\n- **Recent commits:**\n```\n%s\n```' "$git_log"
)$(
[ -n "$git_status" ] && printf '\n- **Uncommitted changes:**\n```\n%s\n```' "$git_status"
[ -z "$git_status" ] && [ -n "$git_branch" ] && printf '\n- **Working tree:** clean'
)

## 最近對話摘要
${conversation_summary}$(
[ -n "$recent_files" ] && printf '\n## 最近操作的檔案\n\n```\n%s\n```' "$recent_files"
)

## Instructions

請先確認你理解上述 context，然後繼續未完成的工作。如果需要更多資訊，先讀取相關檔案再動手。
PROMPT_EOF

  # ── Output ──
  if $raw; then
    echo "$prompt"
  else
    if ! $do_copy; then
      printf "\033[1;36m━━ Resume Prompt ━━\033[0m  \033[90m%s | %s | %d prompts\033[0m\n\n" "$sid" "$topic" "$real_count"
    fi
    echo "$prompt"
    if ! $do_copy; then
      echo
      printf "\033[90m---\033[0m\n"
      printf "\033[90mPaste the above into a new session, or use:\033[0m\n"
      printf "\033[33m  ccs-resume-prompt %s --copy     \033[90m# copy to clipboard\033[0m\n" "$sid"
      printf "\033[33m  claude --resume %s  \033[90m# resume with full context (heavier)\033[0m\n" "$full_sid"
    fi
  fi

  # ── Copy to clipboard ──
  if $do_copy; then
    if command -v xclip &>/dev/null; then
      echo "$prompt" | xclip -selection clipboard
      printf "\033[32mCopied to clipboard!\033[0m (%d chars)\n" "${#prompt}" >&2
    elif command -v xsel &>/dev/null; then
      echo "$prompt" | xsel --clipboard --input
      printf "\033[32mCopied to clipboard!\033[0m (%d chars)\n" "${#prompt}" >&2
    else
      echo "No clipboard tool found (install xclip or xsel)" >&2
      echo "$prompt"
    fi
  fi
}
