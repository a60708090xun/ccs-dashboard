#!/usr/bin/env bash
# ccs-dashboard.sh — Claude Code Session dashboard (personal tool, not official)
# Source this file from .bashrc:  source ~/tools/ccs-dashboard/ccs-dashboard.sh
#
# Commands (from ccs-core.sh):
#   ccs-sessions        — all sessions within N hours
#   ccs-active          — non-archived sessions within N days
#   ccs-cleanup         — kill stopped (suspended) claude processes
#
# Commands (this file):
#   ccs-status  (ccs)   — unified dashboard: active + zombies + stale
#   ccs-pick N          — show details for Nth session from --md list
#   ccs-html            — generate HTML dashboard
#   ccs-details         — interactive session conversation browser
#   ccs-handoff         — generate session handoff note
#   ccs-resume-prompt   — generate bootstrap prompt for new session
#   ccs-overview        — cross-session work overview
#   ccs-checkpoint      — lightweight progress snapshot (Done / In Progress / Blocked)

# ── Load core helpers and basic commands ──
source "${BASH_SOURCE[0]%/*}/ccs-core.sh"

# ── ccs-status (ccs) — unified session dashboard ──
ccs-status() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-status (ccs)  — unified session dashboard
[personal tool, not official Claude Code]

Sections:
  1. Active sessions   — open, non-archived (last 7 days, < 1 day old)
  2. Crashed sessions  — crash-interrupted (detected by ccs-crash logic)
  3. Zombie processes  — stopped claude processes eating RAM
  4. Stale sessions    — open but untouched > 1 day

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
    _ccs_is_archived "$f" || open_files+=("$f")
  done < <(find "$projects_dir" -maxdepth 2 -name "*.jsonl" -mmin -$((7 * 1440)) ! -path "*/subagents/*" -print0 2>/dev/null)

  # Crash detection
  declare -A crash_map
  local -a _status_projects=()
  local _sf
  for _sf in "${open_files[@]}"; do
    local _dname
    _dname=$(basename "$(dirname "$_sf")")
    _status_projects+=("$(_ccs_resolve_project_path "$_dname" 2>/dev/null)")
  done
  _ccs_detect_crash crash_map open_files _status_projects 2>/dev/null

  # Build crash lookup (full sid)
  declare -A crash_full
  local _ck
  for _ck in "${!crash_map[@]}"; do
    [[ "${crash_map[$_ck]}" == high:* ]] && crash_full["$_ck"]=1
  done

  # Split into fresh / crashed / stale
  local fresh_files=() crashed_files=() stale_files=()
  local now
  now=$(date +%s)
  for f in "${open_files[@]}"; do
    local mod ago full_sid
    mod=$(stat -c "%Y" "$f")
    ago=$(( (now - mod) / 60 ))
    full_sid=$(basename "$f" .jsonl)
    if [ -n "${crash_full[$full_sid]+x}" ]; then
      crashed_files+=("$f")
    elif [ "$ago" -lt 1440 ]; then
      fresh_files+=("$f")
    else
      stale_files+=("$f")
    fi
  done

  # ── Markdown mode ──
  if $md; then
    _ccs_status_md "$md_fmt" "$now" "${fresh_files[@]}" "---" "${crashed_files[@]}" "---" "${stale_files[@]}"
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
  printf "\033[1;31m━━ Crashed Sessions ━━\033[0m\n"
  if [ ${#crashed_files[@]} -eq 0 ]; then
    printf "  \033[32m(none)\033[0m\n"
  else
    printf "\033[1m  %-30s %-10s %-10s %s\033[0m\n" "PROJECT" "SESSION" "LAST ACTIVE" "TOPIC"
    for f in "${crashed_files[@]}"; do
      _ccs_session_row "$f"
    done | sort -t$'\t' -k1,1 -k2,2n | while IFS=$'\t' read -r proj _ _ _ display; do
      printf "  \033[31m%s 💀\033[0m\n" "$display"
    done
    printf "\n  \033[1m%d crashed\033[0m → \033[33mccs-crash\033[0m for detail, \033[33mccs-crash --clean\033[0m to dismiss\n" "${#crashed_files[@]}"
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

  # Split args by "---" separators into fresh_files, crashed_files, stale_files
  local fresh_files=() crashed_files=() stale_files=()
  local _section=0
  for arg in "$@"; do
    if [ "$arg" = "---" ]; then _section=$((_section + 1)); continue; fi
    case "$_section" in
      0) fresh_files+=("$arg") ;;
      1) crashed_files+=("$arg") ;;
      2) stale_files+=("$arg") ;;
    esac
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
      project=$(echo "$dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
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

  # Crashed sessions
  echo "### 💀 Crashed Sessions"
  echo
  if [ ${#crashed_files[@]} -eq 0 ]; then
    echo "_(none)_ ✓"
  else
    local crash_sorted
    crash_sorted=$(for f in "${crashed_files[@]}"; do
      local mod ago project dir
      mod=$(stat -c "%Y" "$f")
      ago=$(( (now - mod) / 60 ))
      dir=$(basename "$(dirname "$f")")
      project=$(echo "$dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
      [ -z "$project" ] && project="~(home)"
      printf '%s\t%d\t%s\n' "$project" "$ago" "$f"
    done | sort -t$'\t' -k1,1 -k2,2n)

    while IFS=$'\t' read -r project ago f; do
      local ago_str sid topic full_sid
      session_idx=$((session_idx + 1))
      full_sid=$(basename "$f" .jsonl)
      sid=$(echo "$full_sid" | cut -c1-8)
      topic=$(_ccs_topic_from_jsonl "$f")

      if [ "$ago" -lt 60 ]; then ago_str="${ago}m ago"
      elif [ "$ago" -lt 1440 ]; then ago_str="$((ago / 60))h ago"
      else ago_str="$((ago / 1440))d ago"; fi

      printf '%d\t%s\t%s\n' "$session_idx" "$sid" "$topic" >> "$pick_file"

      if [ "$fmt" = "table" ]; then
        topic=$(echo "$topic" | sed 's/|/\\|/g')
        project=$(echo "$project" | sed 's/|/\\|/g')
        echo "| ${session_idx} | ${project} | \`${sid}\` | ${ago_str} | 💀 crashed | ${topic} |"
      else
        echo "💀 **${session_idx}.** **${topic}** \`${sid}\` ${ago_str}"
        echo
      fi
    done <<< "$crash_sorted"

    echo "> **${#crashed_files[@]}** crashed → \`ccs-crash\` for detail, \`ccs-crash --clean\` to dismiss"
  fi
  echo

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
ccs-pick <N|SESSION-ID> [-n COUNT]  — show details for a session
[personal tool, not official Claude Code]

Accepts a numeric index (from ccs-status --md) or a session ID prefix.

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

  # Accept session ID prefix (non-numeric) or index number
  if [[ "$idx" =~ ^[0-9]+$ ]]; then
    # Numeric — look up in pick index
    sid=$(awk -F'\t' -v n="$idx" '$1 == n {print $2}' "$pick_file")
    topic=$(awk -F'\t' -v n="$idx" '$1 == n {print $3}' "$pick_file")
    if [ -z "$sid" ]; then
      local total
      total=$(wc -l < "$pick_file")
      echo "Invalid index: ${idx} (valid: 1-${total})"
      return 1
    fi
  else
    # Non-numeric — treat as session ID prefix
    sid="$idx"
    topic=""
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
    project=$(echo "$dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
    [ -z "$project" ] && project="~(home)"

    if _ccs_is_archived "$jsonl"; then
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
    _ccs_is_archived "$f" || open_files+=("$f")
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
    project=$(echo "$dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
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
  project=$(echo "$dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
  [ -z "$project" ] && project="~(home)"
  topic=$(_ccs_topic_from_jsonl "$jsonl")

  if _ccs_is_archived "$jsonl"; then
    status="archived"
  else
    local now ago
    now=$(date +%s); ago=$(( (now - $(stat -c "%Y" "$jsonl")) / 60 ))
    if [ "$ago" -lt 10 ]; then status="active"
    elif [ "$ago" -lt 60 ]; then status="recent"
    elif [ "$ago" -lt 1440 ]; then status="idle"
    else status="stale"; fi
  fi

  # ── Build filtered pairs index ──
  # Read both user and assistant entries in one pass to detect interrupted prompts
  local -a real_to_raw=()
  local -a prompts=()
  local -a has_response=()  # "1" = has assistant text, "0" = interrupted/no text
  local raw_idx=0 pending_real=-1

  # Response status: "1" = has response, "resend" = user re-sent, "0" = truly no response
  local -a resp_status=()
  local pending_real=-1 got_assistant=false

  while IFS=$'\t' read -r role is_meta content; do
    if [ "$role" = "U" ]; then
      raw_idx=$((raw_idx + 1))
      # Previous pending prompt: user sent another before getting assistant text
      if [ "$pending_real" -ge 0 ]; then
        resp_status[$pending_real]="resend"  # re-sent (will get response via continuation)
      fi
      # Filter meta/system
      [ "$is_meta" = "true" ] && { pending_real=-1; continue; }
      case "$content" in
        '<local-command'*|'<command-name'*|'<system-'*) pending_real=-1; continue ;;
      esac
      [[ "$content" =~ ^[[:space:]]*/exit ]] && { pending_real=-1; continue; }
      [[ "$content" =~ ^[[:space:]]*/quit ]] && { pending_real=-1; continue; }
      [ -z "${content// /}" ] && { pending_real=-1; continue; }
      real_to_raw+=("$raw_idx")
      prompts+=("$content")
      pending_real=$(( ${#real_to_raw[@]} - 1 ))
    elif [ "$role" = "A" ] && [ "$pending_real" -ge 0 ]; then
      # Got assistant text for the pending prompt
      resp_status[$pending_real]="1"
      pending_real=-1
    fi
  done < <(jq -r '
    if .type == "user" and (.message.content | type == "string") then
      ["U", (.isMeta // false | tostring), (.message.content | .[:100] | gsub("\n"; " "))] | @tsv
    elif .type == "assistant" then
      (.message.content | if type == "array" then
        [.[] | select(.type == "text") | .text] | join("")
      else . end) as $t |
      if ($t | length) > 0 then ["A", "false", ""] | @tsv else empty end
    else empty end
  ' "$jsonl" 2>/dev/null)
  # Handle last pending prompt
  if [ "$pending_real" -ge 0 ]; then
    resp_status[$pending_real]="0"
  fi

  local real_count=${#real_to_raw[@]}

  if [ "$real_count" -eq 0 ]; then
    echo "No user prompts found in session."
    return 1
  fi

  # ── --last mode: non-interactive ──
  if $last_only; then
    printf "\033[1;36m━━ Session Details ━━\033[0m\n"
    printf "  \033[1mSession:\033[0m  %s (%s)  \033[1mProject:\033[0m %s\n" "$sid" "$status" "$project"
    printf "  \033[1mTopic:\033[0m    %s  \033[1mLast:\033[0m %s\n" "$topic" "$mod_date"
    printf "  \033[1mPrompts:\033[0m  %d\n" "$real_count"

    local raw_p=${real_to_raw[$((real_count - 1))]}
    local pair_json
    pair_json=$(_ccs_get_pair "$jsonl" "$raw_p")
    local user_text assistant_text
    user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
    assistant_text=$(echo "$pair_json" | tail -1 | jq -r '.text' 2>/dev/null)
    [ -z "$assistant_text" ] && assistant_text="(no text response — interrupted or tool-only turn)"

    echo
    printf "\033[1;33m━━ Last Prompt [%d/%d] ━━\033[0m\n" "$real_count" "$real_count"
    printf "\033[33m%s\033[0m\n" "$user_text"
    echo
    printf "\033[1;32m━━ Response ━━\033[0m\n"
    echo "$assistant_text" | head -30
    echo
    printf "\033[90mResume: claude --resume %s\033[0m\n" "$full_sid"
    return 0
  fi

  # ── Interactive mode ──
  local sel=$real_count  # start at most recent
  local term_lines key running=true

  while $running; do
    term_lines=$(tput lines 2>/dev/null || echo 24)
    local visible=$((term_lines - 8))  # header takes ~6 lines + footer
    [ "$visible" -lt 5 ] && visible=5

    # Clear screen and draw
    clear
    printf "\033[1;36m━━ %s ━━\033[0m  \033[90m%s | %s | %d prompts\033[0m\n" "$topic" "$sid" "$status" "$real_count"
    printf "\033[90m  ↑↓/jk navigate  PgUp/PgDn page  g/G first/last  Enter view  q quit\033[0m\n"
    printf '%.0s─' {1..80}; echo

    # Calculate window: show prompts around selection
    local win_start win_end
    win_start=$((sel - visible / 2))
    [ "$win_start" -lt 1 ] && win_start=1
    win_end=$((win_start + visible - 1))
    [ "$win_end" -gt "$real_count" ] && win_end=$real_count
    # Adjust start if end hit the limit
    win_start=$((win_end - visible + 1))
    [ "$win_start" -lt 1 ] && win_start=1

    local i
    for ((i = win_start; i <= win_end; i++)); do
      local prompt_text="${prompts[$((i-1))]}"
      local display_num marker="  "
      display_num=$(printf '%3d' "$i")
      # Mark response status: 🚫 = no response, ⏸ = interrupted (re-sent)
      case "${resp_status[$((i-1))]}" in
        0)      marker="\033[31m🚫\033[0m " ;;
        resend) marker="\033[33m⏸\033[0m " ;;
      esac
      if [ "$i" -eq "$sel" ]; then
        printf "  %s %b\033[7m%s\033[0m\n" "$display_num" "$marker" "$prompt_text"
      else
        printf "  \033[90m%s\033[0m %b%s\n" "$display_num" "$marker" "$prompt_text"
      fi
    done

    # Footer
    printf '%.0s─' {1..80}; echo
    printf "\033[90m[%d/%d]\033[0m" "$sel" "$real_count"

    # Read key
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')  # escape sequence
        read -rsn1 -t 0.1 key
        if [ "$key" = "[" ]; then
          read -rsn1 -t 0.1 key
          case "$key" in
            A) [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;           # up
            B) [ "$sel" -lt "$real_count" ] && sel=$((sel + 1)) ;;  # down
            5) read -rsn1 -t 0.1 _  # consume '~'
               sel=$((sel - visible)); [ "$sel" -lt 1 ] && sel=1 ;;  # PgUp
            6) read -rsn1 -t 0.1 _  # consume '~'
               sel=$((sel + visible)); [ "$sel" -gt "$real_count" ] && sel=$real_count ;;  # PgDn
          esac
        elif [ -z "$key" ]; then
          running=false  # bare Esc
        fi
        ;;
      k) [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;
      j) [ "$sel" -lt "$real_count" ] && sel=$((sel + 1)) ;;
      g) sel=1 ;;                    # go to first
      G) sel=$real_count ;;       # go to last
      q) running=false ;;
      '')  # Enter: show full pair
        local raw_p=${real_to_raw[$((sel - 1))]}
        local pair_json user_text assistant_text sel_status
        pair_json=$(_ccs_get_pair "$jsonl" "$raw_p")
        user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
        assistant_text=$(echo "$pair_json" | tail -n +2 | jq -r '.text' 2>/dev/null)
        sel_status="${resp_status[$((sel - 1))]}"
        {
          printf "\033[1;33m━━ Prompt [%d/%d] ━━\033[0m" "$sel" "$real_count"
          case "$sel_status" in
            0)      printf "  \033[31m✗ interrupted\033[0m" ;;
            resend) printf "  \033[33m↻ re-sent\033[0m" ;;
          esac
          echo
          printf "\033[33m%s\033[0m\n" "$user_text"
          echo
          printf "\033[1;32m━━ Response ━━\033[0m\n"
          if [ -z "$assistant_text" ]; then
            printf "\033[90m(no response)\033[0m\n"
          else
            echo "$assistant_text"
            if [ "$sel_status" != "1" ]; then
              echo
              printf "\033[31m⚡ interrupted (response may be incomplete)\033[0m\n"
            fi
          fi
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

Generates a markdown handoff file with auto-filled:
  - Open sessions summary
  - Filtered conversation pairs (user + Claude, skips meta)
  - Git state (branch, commits, uncommitted)
  - Recent file operations (Read/Edit/Write/Bash)
  - TodoWrite task progress (if any)
  - Bootstrap prompt (for pasting into new session)

Output: ~/docs/tmp/handoff/<date>-<topic-slug>.md

Options:
  -n COUNT    Number of conversation pairs to include (default: 5)
  --no-prompt Skip appending bootstrap prompt section
HELP
    return 0
  fi

  local project_dir="" pair_count=5 include_prompt=true
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) pair_count="$2"; shift 2 ;;
      --no-prompt) include_prompt=false; shift ;;
      *) project_dir="$1"; shift ;;
    esac
  done
  [ -z "$project_dir" ] && project_dir="."
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
        _ccs_is_archived "$f" && continue
        printf '%s\t%s\n' "$(stat -c '%Y' "$f")" "$f"
      done | sort -rn
  )

  if [ ${#open_sessions[@]} -eq 0 ]; then
    echo "No open sessions found for: $project_dir"
    return 1
  fi

  # Extract info from the most recent open session
  local latest="${open_sessions[0]}"
  local full_sid sid mod_date topic

  full_sid=$(basename "$latest" .jsonl)
  sid=$(echo "$full_sid" | cut -c1-8)
  mod_date=$(stat -c "%y" "$latest" | cut -d. -f1)

  topic=$(_ccs_topic_from_jsonl "$latest")
  [ -z "$topic" ] && topic="(no topic)"

  # Git context
  local git_branch git_status git_log
  git_branch=$(cd "$project_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "N/A")
  git_status=$(cd "$project_dir" && git status --short 2>/dev/null | head -10)
  git_log=$(cd "$project_dir" && git log --oneline -5 2>/dev/null)

  # Conversation summary (filtered, with Claude responses)
  local conversation_md
  conversation_md=$(_ccs_conversation_md "$latest" "$pair_count")

  # Recent file operations
  local recent_files
  recent_files=$(_ccs_recent_files_md "$latest")

  # TodoWrite progress
  local todos
  todos=$(_ccs_todos_md "$latest")

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
    if [ "$s_topic" = "-" ] || echo "$s_topic" | grep -q '^<'; then
      zombie_count=$((zombie_count + 1))
      continue
    fi
    sessions_summary="${sessions_summary}| \`${s_sid}\` | ${s_age} ago | ${s_topic} |
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
## 對話脈絡

**Session:** \`${sid}\` | **Branch:** \`${git_branch}\` | **Last Active:** ${mod_date}

${conversation_md}
## Git 狀態

\`\`\`
Branch: ${git_branch}

Recent commits:
${git_log:-"(no commits)"}

Uncommitted:
${git_status:-"(clean)"}
\`\`\`
EOF

  # Recent files section (only if non-empty)
  if [ -n "$recent_files" ]; then
    cat >> "$handoff_file" << EOF

## 最近操作的檔案

\`\`\`
${recent_files}
\`\`\`
EOF
  fi

  # TodoWrite progress (only if non-empty)
  if [ -n "$todos" ]; then
    cat >> "$handoff_file" << EOF

## 任務進度（TodoWrite）

${todos}
EOF
  fi

  # Manual sections
  cat >> "$handoff_file" << 'EOF'

## 目前進度

<!-- 補充自動摘要未涵蓋的部分 -->
-

## 下一步

<!-- 下一個 session 應該做什麼 -->
-

## 重要決策

<!-- 這個 session 做了哪些重要決策，為什麼 -->
-
EOF

  # Bootstrap prompt section
  if $include_prompt; then
    local bootstrap
    bootstrap=$(ccs-resume-prompt "$sid" --stdout 2>/dev/null)
    if [ -n "$bootstrap" ]; then
      cat >> "$handoff_file" << EOF

## Bootstrap Prompt

> 直接貼入新 session 即可接手。也可以用 \`ccs-resume-prompt ${sid} --copy\` 複製。

\`\`\`markdown
${bootstrap}
\`\`\`
EOF
    fi
  fi

  echo "Created: $handoff_file"
  echo ""
  echo "  Topic:    ${topic}"
  echo "  Sessions: ${#open_sessions[@]} open"
  echo "  Branch:   ${git_branch}"
  [ -n "$todos" ] && echo "  Tasks:    $(echo "$todos" | wc -l) items"
  [ -n "$recent_files" ] && echo "  Files:    $(echo "$recent_files" | wc -l) operations"
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
  project=$(echo "$dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
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

# ── Helper: extract overview data from a single session JSONL ──
# Outputs a JSON object with: last_exchange, todos, deadline_context
_ccs_overview_session_data() {
  local jsonl="$1"

  # --- Last Exchange (last non-meta user-assistant pair) ---
  # _ccs_get_pair expects a 1-based index into ALL user prompts (including meta).
  # We need to find the raw index of the last non-meta, non-system user prompt.
  # Strategy: enumerate all user prompts with their raw 1-based index,
  # filter out meta/system, take the last one's raw index.
  local user_text="" asst_text=""
  local last_raw_idx
  last_raw_idx=$(jq -c '
    select(.type == "user" and (.message.content | type == "string"))
  ' "$jsonl" 2>/dev/null \
    | jq -sc '
      [to_entries[] | {
        raw_idx: (.key + 1),
        is_meta: (.value.isMeta // false),
        content: .value.message.content
      }]
      | [.[] | select(
          .is_meta == false
          and (.content | test("^\\s*/exit|^\\s*/quit|^<local-command|^<command-name|^<system-") | not)
          and (.content | test("^\\s*$") | not)
        )]
      | last | .raw_idx // 0
    ')

  if [ -n "$last_raw_idx" ] && [ "$last_raw_idx" -gt 0 ]; then
    local pair_json
    pair_json=$(_ccs_get_pair "$jsonl" "$last_raw_idx")
    user_text=$(echo "$pair_json" | head -1 | jq -r '.text // ""' 2>/dev/null | head -1 | cut -c1-120)
    asst_text=$(echo "$pair_json" | tail -1 | jq -r '.text // ""' 2>/dev/null | head -2 | cut -c1-200)
  fi

  # --- Todos (last TodoWrite) ---
  local todos_json
  todos_json=$(jq -c '
    select(.type == "assistant") |
    .message.content[]? |
    select(.type == "tool_use" and .name == "TodoWrite") |
    [.input.todos[]? | {content, status}]
  ' "$jsonl" 2>/dev/null | tail -1)
  [ -z "$todos_json" ] && todos_json="[]"

  # --- Deadline Context (keyword search in last 5 non-meta user messages) ---
  local deadline_ctx=""
  deadline_ctx=$(jq -r '
    select(.type == "user" and (.message.content | type == "string")
      and ((.isMeta // false) == false)) |
    .message.content
  ' "$jsonl" 2>/dev/null \
    | tail -5 \
    | grep -iE '(deadline|before|週|月底|by |due|urgent|ASAP|趕|今天|明天|後天)' \
    | cut -c1-150 \
    | paste -sd '|' -)

  # Output JSON
  jq -nc \
    --arg user_text "$user_text" \
    --arg asst_text "$asst_text" \
    --argjson todos "$todos_json" \
    --arg deadline "$deadline_ctx" \
    '{
      last_exchange: {user: $user_text, assistant: $asst_text},
      todos: $todos,
      deadline_context: (if $deadline == "" then null else $deadline end)
    }'
}

# ── Helper: render overview as Markdown ──
_ccs_overview_md() {
  local -n _files=$1 _projects=$2 _rows=$3
  local count=${#_files[@]}
  local now_str
  now_str=$(date '+%Y-%m-%d %H:%M')

  printf '# Work Overview (%s)\n\n' "$now_str"

  # Crash banner (high confidence only, 4th arg is optional)
  local crash_high=0
  if [ -n "${4:-}" ]; then
    local -n _crash_md=$4
    for sid in "${!_crash_md[@]}"; do
      [[ "${_crash_md[$sid]}" == high:* ]] && crash_high=$((crash_high + 1))
    done
  fi
  if [ "$crash_high" -gt 0 ]; then
    local boot_epoch
    boot_epoch=$(_ccs_get_boot_epoch) || boot_epoch=0
    local boot_str="unknown"
    [ "$boot_epoch" -gt 0 ] && boot_str=$(date -d "@$boot_epoch" '+%H:%M')
    echo ""
    echo "> **偵測到 ${crash_high} 個 crash-interrupted session**（系統重開機 ${boot_str}）"
    echo "> 執行 \`ccs-crash\` 查看詳情，或 \`ccs-crash --all\` 含低信心結果"
    echo ""
  fi

  printf '## Active Sessions (%d)\n\n' "$count"

  if [ "$count" -eq 0 ]; then
    printf '(no active sessions)\n\n'
  fi

  # Collect all todos for cross-session summary
  local -a all_todo_lines=()
  local i

  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local dir="${_projects[$i]}"
    local row="${_rows[$i]}"

    # Parse row fields (tab-separated: project, ago_min, status, color, display...)
    local project ago_min status sid topic
    project=$(echo "$row" | cut -f1)
    ago_min=$(echo "$row" | cut -f2)
    status=$(echo "$row" | cut -f3)

    local resolved_path
    resolved_path=$(_ccs_resolve_project_path "$dir")

    sid=$(basename "$f" .jsonl | cut -c1-8)
    topic=$(_ccs_topic_from_jsonl "$f")

    # Status emoji
    local emoji="🔵"
    case "$status" in
      active)  emoji="🟢" ;;
      recent)  emoji="🟡" ;;
      idle)    emoji="🔵" ;;
      stale)   emoji="⚪" ;;
    esac

    # Override status icon if crash-interrupted (high confidence)
    local full_sid=$(basename "$f" .jsonl)
    if [ -n "${4:-}" ] && [ -n "${_crash_md[$full_sid]+x}" ] && [[ "${_crash_md[$full_sid]}" == high:* ]]; then
      emoji="🔴"
    fi

    # Age string
    local ago_str
    if [ "$ago_min" -lt 60 ]; then
      ago_str="${ago_min}m ago"
    elif [ "$ago_min" -lt 1440 ]; then
      ago_str="$((ago_min / 60))h ago"
    else
      ago_str="$((ago_min / 1440))d ago"
    fi

    # Session data
    local data
    data=$(_ccs_overview_session_data "$f")

    local user_ex asst_ex deadline_ctx
    user_ex=$(echo "$data" | jq -r '.last_exchange.user // ""')
    asst_ex=$(echo "$data" | jq -r '.last_exchange.assistant // ""')
    deadline_ctx=$(echo "$data" | jq -r '.deadline_context // ""')

    printf '### %d. %s %s — %s\n' "$((i + 1))" "$emoji" "$project" "$topic"
    printf -- '- **Session:** %s | %s | %s\n' "$sid" "$project" "$ago_str"

    # Git status (brief)
    if [ -d "$resolved_path/.git" ]; then
      local branch dirty_count
      branch=$(git -C "$resolved_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
      dirty_count=$(git -C "$resolved_path" status --porcelain 2>/dev/null | wc -l)
      if [ "$dirty_count" -gt 0 ]; then
        printf -- '- **Git:** %s (%d uncommitted files)\n' "$branch" "$dirty_count"
      else
        printf -- '- **Git:** %s (clean)\n' "$branch"
      fi
    fi

    # Last Exchange
    if [ -n "$user_ex" ] || [ -n "$asst_ex" ]; then
      printf -- '- **Last Exchange:**\n'
      [ -n "$user_ex" ] && printf '  - **User:** %s\n' "$user_ex"
      [ -n "$asst_ex" ] && printf '  - **Claude:** %s\n' "$asst_ex"
    fi

    # Todos
    local todo_items
    todo_items=$(echo "$data" | jq -r '.todos[]? | (if .status == "completed" then "  - [x] " elif .status == "in_progress" then "  - [~] " else "  - [ ] " end) + .content')
    if [ -n "$todo_items" ]; then
      printf -- '- **Todos:**\n%s\n' "$todo_items"

      # Collect non-completed for cross-session summary
      while IFS=$'\t' read -r t_content t_status; do
        [ "$t_status" = "completed" ] && continue
        local urgency="⚪ 無 deadline"
        [ -n "$deadline_ctx" ] && urgency="🔴 $deadline_ctx"
        all_todo_lines+=("$(printf '%s\t%s\t%s\t%s' "$t_content" "$project" "$t_status" "$urgency")")
      done < <(echo "$data" | jq -r '.todos[]? | [.content, .status] | @tsv')
    else
      printf -- '- **Todos:** (none)\n'
    fi

    # Context (deadline)
    if [ -n "$deadline_ctx" ]; then
      printf -- '- **Context:** %s\n' "$(echo "$deadline_ctx" | sed 's/|/; /g')"
    else
      printf -- '- **Context:** 無明確 deadline\n'
    fi

    printf '\n'
  done

  # Cross-session pending todos
  if [ ${#all_todo_lines[@]} -gt 0 ]; then
    printf '## Pending Todos (cross-session)\n\n'
    printf '| # | Task | Project | Status | Urgency |\n'
    printf '|---|------|---------|--------|---------|\n'
    local n=0
    for line in "${all_todo_lines[@]}"; do
      n=$((n + 1))
      local t_content t_project t_status t_urgency
      t_content=$(echo "$line" | cut -f1)
      t_project=$(echo "$line" | cut -f2)
      t_status=$(echo "$line" | cut -f3)
      t_urgency=$(echo "$line" | cut -f4)
      printf '| %d | %s | %s | %s | %s |\n' "$n" "$t_content" "$t_project" "$t_status" "$t_urgency"
    done
    printf '\n'
  fi

  # Zombie processes (count only)
  local zombie_count
  zombie_count=$(ps aux 2>/dev/null | grep -c '[c]laude.*--session' || echo 0)
  local stopped_count
  stopped_count=$(ps -eo pid,stat,comm 2>/dev/null | awk '$2 ~ /T/ && $3 ~ /claude/' | wc -l)
  if [ "$stopped_count" -gt 0 ]; then
    local zombie_ram
    zombie_ram=$(ps -eo stat,rss,comm 2>/dev/null | awk '$1 ~ /T/ && $3 ~ /claude/ {sum+=$2} END {printf "%d", sum/1024}')
    printf '## Zombie Processes\n\n'
    printf '%d stopped process(es), ~%d MB RAM. Run `ccs-cleanup --dry-run` for details.\n\n' "$stopped_count" "$zombie_ram"
  else
    printf '## Zombie Processes\n\n(none)\n\n'
  fi

  # Feature tracking hint
  local feature_count=0
  local features_file="$(_ccs_data_dir)/features.jsonl"
  if [ -f "$features_file" ]; then
    feature_count=$(grep -cv '^{"id":"_ungrouped"' "$features_file" 2>/dev/null || echo 0)
  fi
  if [ "$feature_count" -gt 0 ]; then
    printf '> %d features tracked — `ccs-feature` for details\n' "$feature_count"
  fi
}

# ── Helper: render overview as JSON ──
# Uses temp files to avoid "Argument list too long" with many sessions.
_ccs_overview_json() {
  local -n _files=$1 _projects=$2 _rows=$3
  # Set up crash nameref if 4th arg provided
  if [ -n "${4:-}" ]; then
    local -n _crash_json=$4
  fi
  local count=${#_files[@]}
  local now_str
  now_str=$(date -Iseconds)

  local tmpdir="${BASH_SOURCE[0]%/*}/tmp"
  mkdir -p "$tmpdir"
  local sessions_tmp="$tmpdir/.overview-sessions.jsonl"
  local todos_tmp="$tmpdir/.overview-todos.jsonl"
  : > "$sessions_tmp"
  : > "$todos_tmp"

  local i
  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local dir="${_projects[$i]}"
    local row="${_rows[$i]}"

    local project ago_min status
    project=$(echo "$row" | cut -f1)
    ago_min=$(echo "$row" | cut -f2)
    status=$(echo "$row" | cut -f3)

    local resolved_path
    resolved_path=$(_ccs_resolve_project_path "$dir")

    local sid
    sid=$(basename "$f" .jsonl | cut -c1-8)
    local topic
    topic=$(_ccs_topic_from_jsonl "$f")

    local data
    data=$(_ccs_overview_session_data "$f")

    # Git info
    local git_branch="null" git_dirty=0
    if [ -d "$resolved_path/.git" ]; then
      git_branch=$(git -C "$resolved_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
      git_dirty=$(git -C "$resolved_path" status --porcelain 2>/dev/null | wc -l)
    fi

    # Per-session crash fields (4th arg is optional)
    local crash_interrupted=false crash_confidence=""
    local full_sid=$(basename "$f" .jsonl)
    if [ -n "${4:-}" ] && [ -n "${_crash_json[$full_sid]+x}" ]; then
      crash_interrupted=true
      crash_confidence="${_crash_json[$full_sid]%%:*}"
    fi

    # Write session object to temp file (one JSON per line)
    jq -nc \
      --arg sid "$sid" \
      --arg project "$project" \
      --arg path "$resolved_path" \
      --argjson ago "$ago_min" \
      --arg status "$status" \
      --arg topic "$topic" \
      --arg git_branch "$git_branch" \
      --argjson git_dirty "$git_dirty" \
      --argjson data "$data" \
      --argjson c_int "$crash_interrupted" \
      --arg c_conf "$crash_confidence" \
      '{
        session_id: $sid,
        project: $project,
        path: $path,
        ago_minutes: $ago,
        status: $status,
        topic: $topic,
        git: {branch: $git_branch, uncommitted_files: $git_dirty},
        last_exchange: $data.last_exchange,
        todos: $data.todos,
        deadline_context: $data.deadline_context,
      }
      + if $c_int then {crash_interrupted: true, crash_confidence: $c_conf} else {} end
      ' >> "$sessions_tmp"

    # Collect pending todos
    echo "$data" | jq -c --arg proj "$project" '.todos[]? | select(.status != "completed") | {content, status, project: $proj}' >> "$todos_tmp"
  done

  # Zombie count
  local stopped_count
  stopped_count=$(ps -eo pid,stat,comm 2>/dev/null | awk '$2 ~ /T/ && $3 ~ /claude/' | wc -l)

  # crash_detected field (4th arg is optional)
  local -a crash_high_sids=()
  if [ -n "${4:-}" ]; then
    for sid in "${!_crash_json[@]}"; do
      [[ "${_crash_json[$sid]}" == high:* ]] && crash_high_sids+=("$sid")
    done
  fi

  local crash_json="null"
  if [ ${#crash_high_sids[@]} -gt 0 ]; then
    local boot_epoch
    boot_epoch=$(_ccs_get_boot_epoch) || boot_epoch=0
    local boot_iso="null"
    [ "$boot_epoch" -gt 0 ] && boot_iso="\"$(date -d "@$boot_epoch" --iso-8601=seconds)\""

    local sids_json=$(printf '%s\n' "${crash_high_sids[@]}" | jq -R '[.,inputs]')
    crash_json=$(jq -nc --argjson boot "$boot_iso" --argjson sids "$sids_json" \
      '{boot_time: $boot, affected_sessions: $sids, count: ($sids | length)}')
  fi

  # Assemble final JSON from temp files
  local sessions_arr todos_arr
  sessions_arr=$(jq -sc '.' "$sessions_tmp" 2>/dev/null || echo '[]')
  todos_arr=$(jq -sc '.' "$todos_tmp" 2>/dev/null || echo '[]')

  jq -nc \
    --arg timestamp "$now_str" \
    --argjson sessions "$sessions_arr" \
    --argjson pending_todos "$todos_arr" \
    --argjson zombie_count "$stopped_count" \
    --argjson crash "$crash_json" \
    '{
      timestamp: $timestamp,
      active_sessions: ($sessions | length),
      sessions: $sessions,
      pending_todos: $pending_todos,
      zombie_processes: $zombie_count,
      crash_detected: $crash
    }'

  rm -f "$sessions_tmp" "$todos_tmp"
}

# ── Helper: render todos-only view ──
_ccs_overview_todos() {
  local -n _files=$1 _projects=$2 _rows=$3
  local mode="$4"
  local count=${#_files[@]}
  local -a todo_entries=()
  local i

  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local row="${_rows[$i]}"
    local project
    project=$(echo "$row" | cut -f1)

    local data
    data=$(_ccs_overview_session_data "$f")

    while IFS=$'\t' read -r t_content t_status; do
      [ "$t_status" = "completed" ] && continue
      local deadline_ctx
      deadline_ctx=$(echo "$data" | jq -r '.deadline_context // ""')
      todo_entries+=("$(printf '%s\t%s\t%s\t%s' "$t_content" "$project" "$t_status" "$deadline_ctx")")
    done < <(echo "$data" | jq -r '.todos[]? | [.content, .status] | @tsv')
  done

  if [ "$mode" = "json" ]; then
    local tmpdir="${BASH_SOURCE[0]%/*}/tmp"
    mkdir -p "$tmpdir"
    local tmp="$tmpdir/.overview-todos-json.jsonl"
    : > "$tmp"
    for entry in "${todo_entries[@]}"; do
      local c p s d
      c=$(echo "$entry" | cut -f1)
      p=$(echo "$entry" | cut -f2)
      s=$(echo "$entry" | cut -f3)
      d=$(echo "$entry" | cut -f4)
      jq -nc --arg c "$c" --arg p "$p" --arg s "$s" --arg d "$d" \
        '{content: $c, project: $p, status: $s, deadline_context: (if $d == "" then null else $d end)}' >> "$tmp"
    done
    jq -sc '.' "$tmp" 2>/dev/null || echo '[]'
    rm -f "$tmp"
    return
  fi

  # Markdown or terminal
  local now_str
  now_str=$(date '+%Y-%m-%d %H:%M')
  printf '# Pending Todos (%s)\n\n' "$now_str"

  if [ ${#todo_entries[@]} -eq 0 ]; then
    printf '(no pending todos across sessions)\n'
    return
  fi

  printf '| # | Task | Project | Status | Urgency |\n'
  printf '|---|------|---------|--------|---------|\n'
  local n=0
  for entry in "${todo_entries[@]}"; do
    n=$((n + 1))
    local c p s d
    c=$(echo "$entry" | cut -f1)
    p=$(echo "$entry" | cut -f2)
    s=$(echo "$entry" | cut -f3)
    d=$(echo "$entry" | cut -f4)
    [ -z "$d" ] && d="—"
    printf '| %d | %s | %s | %s | %s |\n' "$n" "$c" "$p" "$s" "$d"
  done
  printf '\n'
}

# ── Helper: cross-session file operations view ──
_ccs_overview_files() {
  local -n __of_files=$1 __of_projects=$2
  local mode="$3" all_ops="${4:-false}"
  local count=${#__of_files[@]}

  # Collect file operations from all sessions
  local tmp_ops
  tmp_ops=$(mktemp "$(_ccs_data_dir)/files_ops.tmp.XXXXXX")

  local i
  for ((i = 0; i < count; i++)); do
    local _of="${__of_files[$i]}"
    local _dir="${__of_projects[$i]}"
    local _sid
    _sid=$(basename "$_of" .jsonl | cut -c1-4)
    local _mod
    _mod=$(stat -c "%Y" "$_of" 2>/dev/null || echo 0)

    # Extract file operations with jq
    local ops_filter
    if $all_ops; then
      ops_filter='if .name == "Read" then "R\t" + .input.file_path
        elif .name == "Edit" then "E\t" + .input.file_path
        elif .name == "Write" then "W\t" + .input.file_path
        else empty end'
    else
      ops_filter='if .name == "Edit" then "E\t" + .input.file_path
        elif .name == "Write" then "W\t" + .input.file_path
        else empty end'
    fi

    jq -r --arg sid "$_sid" --arg dir "$_dir" --arg ts "$_mod" '
      select(.type == "assistant") |
      .message.content[]? |
      select(.type == "tool_use") |
      '"$ops_filter"' | . + "\t" + $sid + "\t" + $dir + "\t" + $ts
    ' "$_of" 2>/dev/null >> "$tmp_ops"
  done

  if [ "$mode" = "json" ]; then
    _ccs_overview_files_json "$tmp_ops"
    rm -f "$tmp_ops"
    return
  fi

  # Group by project, then by file
  # Format: op\tpath\tsid\tdir\ttimestamp
  local total_files
  total_files=$(cut -f2 "$tmp_ops" 2>/dev/null | sort -u | wc -l)
  local session_count=$count

  printf '## File Operations (across %d sessions)\n\n' "$session_count"

  local -A file_ops=() file_sessions=() file_last_ts=()

  # Get unique projects
  local -a projects
  mapfile -t projects < <(cut -f4 "$tmp_ops" 2>/dev/null | sort -u)

  for proj_dir in "${projects[@]}"; do
    [ -z "$proj_dir" ] && continue
    local proj_name
    proj_name=$(echo "$proj_dir" | sed "s/^${_CCS_HOME_ENCODED}-*//; s/-/\//g")
    [ -z "$proj_name" ] && proj_name="~(home)"

    # Get files for this project, sorted by last timestamp desc
    file_ops=() file_sessions=() file_last_ts=()
    while IFS=$'\t' read -r op path sid dir ts; do
      [ "$dir" != "$proj_dir" ] && continue
      [ -z "$path" ] && continue
      # Shorten path: remove project prefix
      local short_path="$path"

      local key="$short_path"
      file_ops[$key]+="${op}"
      if [[ "${file_sessions[$key]}" != *"$sid"* ]]; then
        file_sessions[$key]+="${sid}, "
      fi
      if [ -z "${file_last_ts[$key]}" ] || [ "$ts" -gt "${file_last_ts[$key]}" ]; then
        file_last_ts[$key]="$ts"
      fi
    done < "$tmp_ops"

    local proj_file_count=${#file_ops[@]}
    [ "$proj_file_count" -eq 0 ] && continue

    printf '### %s (%d files)\n' "$proj_name" "$proj_file_count"
    printf '| File | Ops | Sessions | Last |\n'
    printf '|------|-----|----------|------|\n'

    # Sort by last_ts desc
    local -a sorted_files=()
    for key in "${!file_last_ts[@]}"; do
      sorted_files+=("${file_last_ts[$key]}"$'\t'"$key")
    done
    local sorted
    sorted=$(printf '%s\n' "${sorted_files[@]}" | sort -rn)

    while IFS=$'\t' read -r _ts key; do
      [ -z "$key" ] && continue
      local ops="${file_ops[$key]}"
      local sessions="${file_sessions[$key]}"
      sessions="${sessions%, }"  # trim trailing comma

      # Count ops
      local r_count e_count w_count ops_str=""
      r_count=$(echo "$ops" | grep -o 'R' | wc -l)
      e_count=$(echo "$ops" | grep -o 'E' | wc -l)
      w_count=$(echo "$ops" | grep -o 'W' | wc -l)
      [ "$e_count" -gt 0 ] && ops_str+="E×${e_count} "
      [ "$w_count" -gt 0 ] && ops_str+="W×${w_count} "
      [ "$r_count" -gt 0 ] && ops_str+="R×${r_count} "
      ops_str="${ops_str% }"

      local now ago
      now=$(date +%s)
      ago=$(( (now - _ts) / 60 ))

      # Shorten file path for display
      local display_path="$key"
      if [ ${#display_path} -gt 60 ]; then
        display_path="...${display_path: -57}"
      fi

      printf '| %s | %s | %s | %s |\n' "$display_path" "$ops_str" "$sessions" "$(_ccs_ago_str "$ago")"
    done <<< "$sorted"

    printf '\n'

    # Clear associative arrays for next project
    file_ops=()
    file_sessions=()
    file_last_ts=()
  done

  rm -f "$tmp_ops"
}

_ccs_overview_files_json() {
  local tmp_ops="$1"
  [ ! -s "$tmp_ops" ] && { echo "[]"; return; }

  # Build JSON from raw ops
  local -A file_data=()
  while IFS=$'\t' read -r op path sid dir ts; do
    [ -z "$path" ] && continue
    local key="$path"
    if [ -z "${file_data[$key]+x}" ]; then
      file_data[$key]=$(jq -nc --arg p "$path" --arg d "$dir" '{"path":$p,"dir":$d,"R":0,"E":0,"W":0,"sessions":[],"last_ts":0}')
    fi
    file_data[$key]=$(echo "${file_data[$key]}" | jq \
      --arg op "$op" --arg sid "$sid" --argjson ts "$ts" \
      '.[$op] += 1 | .sessions = (.sessions + [$sid] | unique) | .last_ts = ([.last_ts, $ts] | max)')
  done < "$tmp_ops"

  local result="["
  local first=true
  for key in "${!file_data[@]}"; do
    $first || result+=","
    first=false
    result+="${file_data[$key]}"
  done
  result+="]"

  echo "$result" | jq 'sort_by(-.last_ts)'
}

# ── Helper: render cross-project git status ──
_ccs_overview_git() {
  local -n _files=$1 _projects=$2
  local mode="$3" git_commits="${4:-3}"
  local count=${#_files[@]}

  # Deduplicate projects
  local -A seen_projects=()
  local -a unique_dirs=()
  local i
  for ((i = 0; i < count; i++)); do
    local dir="${_projects[$i]}"
    if [ -z "${seen_projects[$dir]+x}" ]; then
      seen_projects[$dir]=1
      unique_dirs+=("$dir")
    fi
  done

  local proj_count=${#unique_dirs[@]}

  if [ "$mode" = "json" ]; then
    _ccs_overview_git_json unique_dirs "$git_commits"
    return
  fi

  # Markdown output
  printf '## Git Status (%d projects)\n\n' "$proj_count"

  local n=0
  for dir in "${unique_dirs[@]}"; do
    local resolved
    resolved=$(_ccs_resolve_project_path "$dir")
    [ ! -d "$resolved/.git" ] && continue

    n=$((n + 1))
    local branch dirty_count ahead behind stash_count
    branch=$(git -C "$resolved" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

    local porcelain
    porcelain=$(git -C "$resolved" status --porcelain 2>/dev/null)
    dirty_count=0
    local modified_count=0 untracked_count=0
    if [ -n "$porcelain" ]; then
      dirty_count=$(echo "$porcelain" | wc -l)
      modified_count=$(echo "$porcelain" | grep -c '^ *[MADRCU]' || true)
      untracked_count=$(echo "$porcelain" | grep -c '^?' || true)
    fi

    # Ahead/behind
    ahead=0; behind=0
    if git -C "$resolved" rev-parse --verify '@{u}' &>/dev/null; then
      local lr
      lr=$(git -C "$resolved" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
      behind=$(echo "$lr" | awk '{print $1+0}')
      ahead=$(echo "$lr" | awk '{print $2+0}')
    fi

    stash_count=$(git -C "$resolved" stash list 2>/dev/null | wc -l)

    local project
    project=$(echo "$resolved" | sed "s|^$HOME/||")
    [ -z "$project" ] && project="~(home)"

    local icon="✅"
    [ "$dirty_count" -gt 0 ] || [ "$ahead" -gt 0 ] && icon="⚠️"

    printf '### %d. %s %s — %s\n' "$n" "$icon" "$project" "$branch"

    if [ "$dirty_count" -eq 0 ] && [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
      printf -- '- **Clean**\n'
    else
      if [ "$dirty_count" -gt 0 ]; then
        printf -- '- **Uncommitted:** %d files (%d modified, %d untracked)\n' "$dirty_count" "$modified_count" "$untracked_count"
      fi
      printf -- '- **Ahead/Behind:** ↑%d ↓%d' "$ahead" "$behind"
      [ "$ahead" -gt 0 ] && printf ' (%d commits unpushed)' "$ahead"
      printf '\n'
      [ "$stash_count" -gt 0 ] && printf -- '- **Stash:** %d entry/entries\n' "$stash_count"
      if [ "$dirty_count" -gt 0 ]; then
        local modified_files
        modified_files=$(echo "$porcelain" | cut -c4- | head -5 | paste -sd ', ' -)
        printf -- '- **Modified:** %s\n' "$modified_files"
        [ "$dirty_count" -gt 5 ] && printf '  ... and %d more\n' "$((dirty_count - 5))"
      fi
    fi
    if [ "$git_commits" -gt 0 ]; then
      printf -- '- **Recent Commits:**\n'
      git -C "$resolved" log --oneline --format="  - %h %ar — %s" -"$git_commits" 2>/dev/null
    fi
    printf '\n'
  done

  [ "$n" -eq 0 ] && printf '(no git repositories found)\n\n'
}

# ── Helper: git status as JSON ──
_ccs_overview_git_json() {
  local -n _dirs=$1
  local git_commits="${2:-3}"
  local result="[]"

  for dir in "${_dirs[@]}"; do
    local resolved
    resolved=$(_ccs_resolve_project_path "$dir")
    [ ! -d "$resolved/.git" ] && continue

    local branch dirty ahead=0 behind=0 stash_count
    branch=$(git -C "$resolved" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    dirty=$(git -C "$resolved" status --porcelain 2>/dev/null | wc -l)
    if git -C "$resolved" rev-parse --verify '@{u}' &>/dev/null; then
      local lr
      lr=$(git -C "$resolved" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
      behind=$(echo "$lr" | cut -f1)
      ahead=$(echo "$lr" | cut -f2)
    fi
    stash_count=$(git -C "$resolved" stash list 2>/dev/null | wc -l)

    local project
    project=$(echo "$resolved" | sed "s|^$HOME/||")
    [ -z "$project" ] && project="~(home)"

    local commits_json="[]"
    if [ "$git_commits" -gt 0 ]; then
      commits_json=$(git -C "$resolved" log --format='%h%x1f%ar%x1f%s' -"$git_commits" 2>/dev/null | while IFS=$'\x1f' read -r _h _a _m; do jq -nc --arg h "$_h" --arg a "$_a" --arg m "$_m" '{hash:$h,ago:$a,message:$m}'; done | jq -sc '.')
      [ -z "$commits_json" ] && commits_json="[]"
    fi

    result=$(echo "$result" | jq \
      --arg proj "$project" \
      --arg path "$resolved" \
      --arg branch "$branch" \
      --argjson dirty "$dirty" \
      --argjson ahead "$ahead" \
      --argjson behind "$behind" \
      --argjson stash "$stash_count" \
      --argjson commits "$commits_json" \
      '. + [{project: $proj, path: $path, branch: $branch, uncommitted: $dirty, ahead: $ahead, behind: $behind, stash: $stash, recent_commits: $commits}]')
  done

  echo "$result" | jq .
}

# ── Helper: render overview as terminal ANSI ──
_ccs_overview_terminal() {
  local -n _files=$1 _projects=$2 _rows=$3
  local count=${#_files[@]}
  local now_str
  now_str=$(date '+%Y-%m-%d %H:%M')

  # Crash detection (4th arg is optional)
  local crash_high=0
  if [ -n "${4:-}" ]; then
    local -n _crash_term=$4
    local _csid
    for _csid in "${!_crash_term[@]}"; do
      [[ "${_crash_term[$_csid]}" == high:* ]] && crash_high=$((crash_high + 1))
    done
  fi

  printf '\033[1m── Work Overview (%s) ──\033[0m\n\n' "$now_str"

  if [ "$count" -eq 0 ]; then
    printf '  \033[90m(no active sessions)\033[0m\n\n'
    return
  fi

  printf '\033[1mActive Sessions (%d)\033[0m\n' "$count"

  if [ "$crash_high" -gt 0 ]; then
    printf '  \033[31m💀 %d crash-interrupted session(s) — ccs-crash for detail\033[0m\n' "$crash_high"
  fi

  local i
  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local row="${_rows[$i]}"

    local project ago_min status color
    project=$(echo "$row" | cut -f1)
    ago_min=$(echo "$row" | cut -f2)
    status=$(echo "$row" | cut -f3)
    color=$(echo "$row" | cut -f4)

    # Override color for crash-interrupted sessions (high confidence)
    local full_sid
    full_sid=$(basename "$f" .jsonl)
    local crash_suffix=""
    if [ -n "${4:-}" ] && [ -n "${_crash_term[$full_sid]+x}" ] && [[ "${_crash_term[$full_sid]}" == high:* ]]; then
      color="\033[31m"
      crash_suffix=" 💀"
    fi

    local sid="${full_sid:0:8}"
    local topic
    topic=$(_ccs_topic_from_jsonl "$f")

    local ago_str
    if [ "$ago_min" -lt 60 ]; then
      ago_str="${ago_min}m"
    elif [ "$ago_min" -lt 1440 ]; then
      ago_str="$((ago_min / 60))h"
    else
      ago_str="$((ago_min / 1440))d"
    fi

    # Brief line: [status] sid project (age) — topic
    printf '  %b%s %-25s\033[0m \033[90m%4s\033[0m  %s%s\n' "$color" "$sid" "$project" "$ago_str" "$topic" "$crash_suffix"

    # Todos (compact)
    local data
    data=$(_ccs_overview_session_data "$f")
    local pending_count
    pending_count=$(echo "$data" | jq '[.todos[]? | select(.status != "completed")] | length')
    local in_progress
    in_progress=$(echo "$data" | jq -r '[.todos[]? | select(.status == "in_progress") | .content] | first // empty')

    if [ -n "$in_progress" ]; then
      printf '    \033[33m↳ %s\033[0m\n' "$in_progress"
    elif [ "$pending_count" -gt 0 ]; then
      printf '    \033[90m↳ %d pending todo(s)\033[0m\n' "$pending_count"
    fi
  done

  # Zombie summary
  local stopped_count
  stopped_count=$(ps -eo pid,stat,comm 2>/dev/null | awk '$2 ~ /T/ && $3 ~ /claude/' | wc -l)
  if [ "$stopped_count" -gt 0 ]; then
    printf '\n\033[31m⚠ %d zombie process(es)\033[0m — run \033[1mccs-cleanup --dry-run\033[0m\n' "$stopped_count"
  fi

  printf '\n'
}

# ── Feature clustering engine ──

_ccs_data_dir() {
  local dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard"
  mkdir -p "$dir"
  echo "$dir"
}

# Extract first issue ref from topic string
# Returns: "gl65" or "gh12" or empty
_ccs_extract_issue_ref() {
  local topic="$1"
  echo "$topic" | grep -oiP '(GL|GH)#\d+' | head -1 | tr '[:upper:]' '[:lower:]' | tr -d '#'
}

# Convert branch name to slug: feat/write-then-verify → feat-write-then-verify
_ccs_branch_slug() {
  echo "$1" | tr '/' '-' | tr '[:upper:]' '[:lower:]'
}

# Read overrides.jsonl with error tolerance
_ccs_read_overrides() {
  local overrides_file="$(_ccs_data_dir)/overrides.jsonl"
  [ ! -f "$overrides_file" ] && return 0
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [ -z "$line" ] && continue
    if ! echo "$line" | jq -e . &>/dev/null; then
      echo "ccs: warning: overrides.jsonl line $line_num: malformed JSON, skipping" >&2
      continue
    fi
    echo "$line"
  done < "$overrides_file"
}

# Infer feature status from metrics
# Args: todos_done todos_total last_active_min has_in_progress_todo
_ccs_feature_status() {
  local todos_done=$1 todos_total=$2 last_min=$3 has_ip=$4
  if [ "$has_ip" = "true" ] || [ "$last_min" -lt 180 ]; then
    echo "in_progress"
  elif [ "$last_min" -gt 1440 ] && [ "$todos_total" -gt "$todos_done" ]; then
    echo "stale"
  elif [ "$todos_total" -gt 0 ] && [ "$todos_done" -eq "$todos_total" ] && [ "$last_min" -ge 180 ]; then
    echo "completed"
  else
    echo "idle"
  fi
}

# Main clustering engine
# Args: session_files session_projects session_rows (nameref arrays)
# Writes features.jsonl to data dir
_ccs_feature_cluster() {
  local -n __fc_files=$1 __fc_projects=$2 __fc_rows=$3
  local count=${#__fc_files[@]}
  [ "$count" -eq 0 ] && return 0

  # Read overrides into associative arrays
  local -A override_assign=()   # session -> feature_id
  local -A override_exclude=()  # "session:feature_id" -> 1
  local ovr_line
  while IFS= read -r ovr_line; do
    [ -z "$ovr_line" ] && continue
    local ovr_session ovr_feature ovr_action
    ovr_session=$(echo "$ovr_line" | jq -r '.session // ""')
    ovr_feature=$(echo "$ovr_line" | jq -r '.feature // ""')
    ovr_action=$(echo "$ovr_line" | jq -r '.action // ""')
    if [ "$ovr_action" = "assign" ] && [ -n "$ovr_session" ] && [ -n "$ovr_feature" ]; then
      override_assign[$ovr_session]="$ovr_feature"
    elif [ "$ovr_action" = "exclude" ] && [ -n "$ovr_session" ] && [ -n "$ovr_feature" ]; then
      override_exclude["${ovr_session}:${ovr_feature}"]=1
    fi
  done < <(_ccs_read_overrides)

  # Phase 1: Assign each session to a feature (or ungrouped)
  # feature_sessions: feature_id -> space-separated session indices
  local -A feature_sessions=()
  local -A feature_labels=()
  local -A feature_projects=()
  local -A feature_branches=()
  local -a ungrouped_indices=()

  local i
  for ((i = 0; i < count; i++)); do
    local f="${__fc_files[$i]}"
    local dir="${__fc_projects[$i]}"
    local row="${__fc_rows[$i]}"

    # Parse row fields (tab-separated) + get topic from JSONL
    local project sid topic
    project=$(echo "$row" | cut -f1)
    sid=$(basename "$f" .jsonl | cut -c1-8)
    topic=$(_ccs_topic_from_jsonl "$f")

    # Friendly project name for feature ID prefix
    local proj_prefix
    proj_prefix=$(echo "$project" | sed 's|.*/||; s|~(home)||')
    [ -z "$proj_prefix" ] && proj_prefix="home"

    local feature_id=""

    # 1. Check override assign (match by sid prefix)
    local ovr_key
    for ovr_key in "${!override_assign[@]}"; do
      if [[ "$sid" == "${ovr_key}"* ]]; then
        feature_id="${override_assign[$ovr_key]}"
        break
      fi
    done

    # 2. Check override exclude
    if [ -n "$feature_id" ]; then
      local excl_key="${sid}:${feature_id}"
      local excl_match=false
      for ovr_key in "${!override_exclude[@]}"; do
        local excl_sid="${ovr_key%%:*}"
        local excl_fid="${ovr_key#*:}"
        if [[ "$sid" == "${excl_sid}"* ]] && [ "$excl_fid" = "$feature_id" ]; then
          excl_match=true
          break
        fi
      done
      if $excl_match; then
        feature_id=""
      fi
    fi

    # 3. Extract issue ref from topic
    if [ -z "$feature_id" ]; then
      local issue_ref
      issue_ref=$(_ccs_extract_issue_ref "$topic")
      if [ -n "$issue_ref" ]; then
        feature_id="${proj_prefix}/${issue_ref}"
        [ -z "${feature_labels[$feature_id]+x}" ] && feature_labels[$feature_id]="$topic"
      fi
    fi

    # 4. Check git branch (non-default)
    if [ -z "$feature_id" ]; then
      local resolved
      resolved=$(_ccs_resolve_project_path "$dir")
      if [ -d "$resolved/.git" ]; then
        local branch
        branch=$(git -C "$resolved" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ -n "$branch" ] && [[ "$branch" != "master" && "$branch" != "main" && "$branch" != "develop" ]]; then
          local slug
          slug=$(_ccs_branch_slug "$branch")
          feature_id="${proj_prefix}/${slug}"
          [ -z "${feature_labels[$feature_id]+x}" ] && feature_labels[$feature_id]="$branch"
          feature_branches[$feature_id]="$branch"
        fi
      fi
    fi

    # 5. Ungrouped
    if [ -z "$feature_id" ]; then
      ungrouped_indices+=("$i")
      continue
    fi

    # Check exclude for auto-detected features
    local excl_match=false
    for ovr_key in "${!override_exclude[@]}"; do
      local excl_sid="${ovr_key%%:*}"
      local excl_fid="${ovr_key#*:}"
      if [[ "$sid" == "${excl_sid}"* ]] && [ "$excl_fid" = "$feature_id" ]; then
        excl_match=true
        break
      fi
    done
    if $excl_match; then
      ungrouped_indices+=("$i")
      continue
    fi

    # Add to feature
    feature_sessions[$feature_id]+="$i "
    [ -z "${feature_projects[$feature_id]+x}" ] && feature_projects[$feature_id]="$project"
  done

  # Phase 2: Aggregate per-feature stats and write features.jsonl
  local data_dir
  data_dir=$(_ccs_data_dir)
  local tmp_features
  tmp_features=$(mktemp "${data_dir}/features.tmp.XXXXXX")

  local fid
  for fid in "${!feature_sessions[@]}"; do
    local indices="${feature_sessions[$fid]}"
    local label="${feature_labels[$fid]:-$fid}"
    local fproject="${feature_projects[$fid]:-unknown}"
    local fbranch="${feature_branches[$fid]:-}"

    local -a session_ids=()
    local todos_done=0 todos_total=0 has_ip=false
    local min_ago=999999 last_exchange=""
    local git_dirty=0

    local idx
    for idx in $indices; do
      local _sf="${__fc_files[$idx]}"
      local _srow="${__fc_rows[$idx]}"
      local s_sid s_ago
      s_sid=$(basename "$_sf" .jsonl | cut -c1-8)
      s_ago=$(echo "$_srow" | cut -f2)
      session_ids+=("$s_sid")

      [ "$s_ago" -lt "$min_ago" ] && min_ago=$s_ago

      # Get session data (todos + last exchange)
      local sdata
      sdata=$(_ccs_overview_session_data "$_sf")
      if [ -n "$sdata" ]; then
        local s_done s_total s_has_ip s_asst
        s_done=$(echo "$sdata" | jq '[.todos[] | select(.status == "completed")] | length')
        s_total=$(echo "$sdata" | jq '.todos | length')
        s_has_ip=$(echo "$sdata" | jq '[.todos[] | select(.status == "in_progress")] | length > 0')
        s_asst=$(echo "$sdata" | jq -r '.last_exchange.assistant // ""' | head -2 | cut -c1-200)
        todos_done=$((todos_done + s_done))
        todos_total=$((todos_total + s_total))
        [ "$s_has_ip" = "true" ] && has_ip=true
        # Most recent session's exchange wins
        if [ "$s_ago" -eq "$min_ago" ] && [ -n "$s_asst" ]; then
          last_exchange="$s_asst"
        fi
      fi
    done

    # Git dirty count (from the feature's project)
    local resolved
    resolved=$(_ccs_resolve_project_path "$(echo "${__fc_projects[${indices%% *}]}")")
    if [ -d "$resolved/.git" ]; then
      git_dirty=$(git -C "$resolved" status --porcelain 2>/dev/null | wc -l)
    fi

    local status
    status=$(_ccs_feature_status "$todos_done" "$todos_total" "$min_ago" "$has_ip")

    local sessions_json
    sessions_json=$(printf '%s\n' "${session_ids[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')

    local updated
    updated=$(date -u +"%Y-%m-%dT%H:%M:%S")

    jq -nc \
      --arg fid "$fid" \
      --arg flabel "$label" \
      --arg fproject "$fproject" \
      --argjson fsessions "$sessions_json" \
      --arg fbranch "$fbranch" \
      --arg fstatus "$status" \
      --argjson ftd "$todos_done" \
      --argjson ftt "$todos_total" \
      --argjson flam "$min_ago" \
      --arg fle "$last_exchange" \
      --argjson fgd "$git_dirty" \
      --arg fup "$updated" \
      '{"id":$fid, "label":$flabel, "project":$fproject, "sessions":$fsessions, "branch":$fbranch,
        "status":$fstatus, "todos_done":$ftd, "todos_total":$ftt,
        "last_active_min":$flam, "last_exchange":$fle,
        "git_dirty":$fgd, "updated":$fup}' >> "$tmp_features"
  done

  # Write ungrouped as a special record
  if [ ${#ungrouped_indices[@]} -gt 0 ]; then
    local -a ug_ids=()
    for idx in "${ungrouped_indices[@]}"; do
      local ug_sid
      ug_sid=$(basename "${__fc_files[$idx]}" .jsonl | cut -c1-8)
      ug_ids+=("$ug_sid")
    done
    local ug_json
    ug_json=$(printf '%s\n' "${ug_ids[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')
    jq -nc --argjson sessions "$ug_json" '{id:"_ungrouped", sessions:$sessions}' >> "$tmp_features"
  fi

  # Atomic rename
  if mv "$tmp_features" "${data_dir}/features.jsonl" 2>/dev/null; then
    : # success
  else
    echo "ccs: warning: failed to write features.jsonl" >&2
    rm -f "$tmp_features" 2>/dev/null
  fi

}

# ── shared session collector ──
# Collect active sessions (non-archived, last 7 days).
# Usage: _ccs_collect_sessions [-a|--all] out_files out_projects out_rows
# Three nameref output arrays.
_ccs_collect_sessions() {
  local show_all=false
  if [ "${1:-}" = "-a" ] || [ "${1:-}" = "--all" ]; then
    show_all=true; shift
  fi

  local -n _out_files=$1 _out_projects=$2 _out_rows=$3

  local sessions_dir="$HOME/.claude/projects"
  [ ! -d "$sessions_dir" ] && return 0

  local cutoff
  cutoff=$(date -d "7 days ago" +%s 2>/dev/null || date -v-7d +%s 2>/dev/null)

  while IFS= read -r f; do
    local mod
    mod=$(stat -c "%Y" "$f" 2>/dev/null)
    [ "$mod" -lt "$cutoff" ] 2>/dev/null && continue

    # Skip archived
    if _ccs_is_archived "$f"; then
      continue
    fi

    local dir sid_prefix
    dir=$(basename "$(dirname "$f")")
    sid_prefix=$(basename "$f" .jsonl | cut -c1-6)

    # Skip subagent sessions unless --all
    if ! $show_all; then
      [[ "$dir" == *subagents* ]] && continue
      [[ "$sid_prefix" == agent-* ]] && continue

      # Skip sessions with no real user prompts
      if ! grep -m1 '"type":"user"' "$f" 2>/dev/null \
        | jq -e 'select((.isMeta // false) == false and (.message.content | type == "string") and (.message.content | test("^<local-command|^<command-name|^<system-") | not))' &>/dev/null; then
        continue
      fi
    fi

    local row
    row=$(_ccs_session_row "$f")
    [ -z "$row" ] && continue

    _out_files+=("$f")
    _out_projects+=("$dir")
    _out_rows+=("$row")
  done < <(find "$sessions_dir" -name "*.jsonl" -type f 2>/dev/null)
}

# ── ccs-feature — feature progress view ──

# Helper: format "N ago" from minutes
_ccs_ago_str() {
  local ago=$1
  if [ "$ago" -lt 60 ]; then
    printf '%dm ago' "$ago"
  elif [ "$ago" -lt 1440 ]; then
    printf '%dh ago' "$((ago / 60))"
  else
    printf '%dd ago' "$((ago / 1440))"
  fi
}

# Status icon mapping
_ccs_feature_icon() {
  case "$1" in
    in_progress) echo "🟢" ;;
    stale)       echo "🟡" ;;
    completed)   echo "✅" ;;
    idle)        echo "🔵" ;;
    *)           echo "⚪" ;;
  esac
}

# Render feature summary as Markdown
_ccs_feature_md() {
  local data_dir
  data_dir=$(_ccs_data_dir)
  local features_file="${data_dir}/features.jsonl"
  [ ! -f "$features_file" ] && { echo "No features found. Run ccs-feature to cluster."; return 0; }

  local feature_count=0 ungrouped_json=""
  local -a feature_lines=()

  while IFS= read -r line; do
    local fid
    fid=$(echo "$line" | jq -r '.id')
    if [ "$fid" = "_ungrouped" ]; then
      ungrouped_json="$line"
      continue
    fi
    feature_lines+=("$line")
    feature_count=$((feature_count + 1))
  done < "$features_file"

  printf '## Features (%d)\n\n' "$feature_count"

  local n=0
  for line in "${feature_lines[@]}"; do
    n=$((n + 1))
    local fid flabel fproject fstatus ftd ftt flam fle fsessions_count
    fid=$(echo "$line" | jq -r '.id')
    flabel=$(echo "$line" | jq -r '.label')
    fproject=$(echo "$line" | jq -r '.project')
    fstatus=$(echo "$line" | jq -r '.status')
    ftd=$(echo "$line" | jq -r '.todos_done')
    ftt=$(echo "$line" | jq -r '.todos_total')
    flam=$(echo "$line" | jq -r '.last_active_min')
    fle=$(echo "$line" | jq -r '.last_exchange // ""' | head -1 | cut -c1-120)
    fsessions_count=$(echo "$line" | jq '.sessions | length')

    local icon ago_str todos_str
    icon=$(_ccs_feature_icon "$fstatus")
    ago_str=$(_ccs_ago_str "$flam")

    if [ "$ftt" -gt 0 ] && [ "$ftd" -eq "$ftt" ]; then
      todos_str="Todos: ${ftd}/${ftt} ✓"
    elif [ "$ftt" -gt 0 ]; then
      todos_str="Todos: ${ftd}/${ftt}"
    else
      todos_str="Todos: (none)"
    fi

    # Extract project short name from project path
    local proj_short
    proj_short=$(echo "$fproject" | sed 's|.*/||')
    [ -z "$proj_short" ] && proj_short="$fproject"

    printf '### %d. %s %s [%s]\n' "$n" "$icon" "$flabel" "$proj_short"
    printf '   %s | Sessions: %d | Last: %s\n' "$todos_str" "$fsessions_count" "$ago_str"
    [ -n "$fle" ] && printf '   最後：%s\n' "$fle"
    printf '\n'
  done

  # Ungrouped sessions
  if [ -n "$ungrouped_json" ]; then
    local ug_count
    ug_count=$(echo "$ungrouped_json" | jq '.sessions | length')
    if [ "$ug_count" -gt 0 ]; then
      printf '## Ungrouped Sessions (%d)\n' "$ug_count"
      # Need session details for ungrouped — read from collected sessions
      local -a ug_sids
      mapfile -t ug_sids < <(echo "$ungrouped_json" | jq -r '.sessions[]')
      for ug_sid in "${ug_sids[@]}"; do
        # Find session file by prefix
        local ug_file
        ug_file=$(find "$HOME/.claude/projects" -name "${ug_sid}*.jsonl" -type f 2>/dev/null | head -1)
        if [ -n "$ug_file" ]; then
          local ug_topic ug_ago
          ug_topic=$(_ccs_topic_from_jsonl "$ug_file")
          local ug_mod ug_now
          ug_mod=$(stat -c "%Y" "$ug_file" 2>/dev/null)
          ug_now=$(date +%s)
          ug_ago=$(( (ug_now - ug_mod) / 60 ))
          printf '   %s  %s (%s)\n' "$ug_sid" "$ug_topic" "$(_ccs_ago_str "$ug_ago")"
        else
          printf '   %s  (file not found)\n' "$ug_sid"
        fi
      done
      printf '\n'
    fi
  fi
}

# Render feature summary as JSON
_ccs_feature_json() {
  local data_dir
  data_dir=$(_ccs_data_dir)
  local features_file="${data_dir}/features.jsonl"
  [ ! -f "$features_file" ] && { echo "[]"; return 0; }

  jq -sc '.' "$features_file"
}

# Render feature summary as Terminal ANSI
_ccs_feature_terminal() {
  local data_dir
  data_dir=$(_ccs_data_dir)
  local features_file="${data_dir}/features.jsonl"
  [ ! -f "$features_file" ] && { echo "No features found."; return 0; }

  local feature_count=0 ungrouped_json=""
  local -a feature_lines=()

  while IFS= read -r line; do
    local fid
    fid=$(echo "$line" | jq -r '.id')
    if [ "$fid" = "_ungrouped" ]; then
      ungrouped_json="$line"
      continue
    fi
    feature_lines+=("$line")
    feature_count=$((feature_count + 1))
  done < "$features_file"

  printf '\033[1mFeatures (%d)\033[0m\n\n' "$feature_count"

  local n=0
  for line in "${feature_lines[@]}"; do
    n=$((n + 1))
    local fid flabel fproject fstatus ftd ftt flam fle fsessions_count
    fid=$(echo "$line" | jq -r '.id')
    flabel=$(echo "$line" | jq -r '.label')
    fproject=$(echo "$line" | jq -r '.project')
    fstatus=$(echo "$line" | jq -r '.status')
    ftd=$(echo "$line" | jq -r '.todos_done')
    ftt=$(echo "$line" | jq -r '.todos_total')
    flam=$(echo "$line" | jq -r '.last_active_min')
    fle=$(echo "$line" | jq -r '.last_exchange // ""' | head -1 | cut -c1-120)
    fsessions_count=$(echo "$line" | jq '.sessions | length')

    local icon ago_str
    icon=$(_ccs_feature_icon "$fstatus")
    ago_str=$(_ccs_ago_str "$flam")

    local proj_short
    proj_short=$(echo "$fproject" | sed 's|.*/||')

    # Color based on status
    local color="\033[0m"
    case "$fstatus" in
      in_progress) color="\033[32m" ;;
      stale)       color="\033[33m" ;;
      completed)   color="\033[90m" ;;
      idle)        color="\033[34m" ;;
    esac

    printf '%s %d. %b%s\033[0m [%s]\n' "$icon" "$n" "$color" "$flabel" "$proj_short"

    local todos_str
    if [ "$ftt" -gt 0 ] && [ "$ftd" -eq "$ftt" ]; then
      todos_str="${ftd}/${ftt} ✓"
    elif [ "$ftt" -gt 0 ]; then
      todos_str="${ftd}/${ftt}"
    else
      todos_str="—"
    fi

    printf '   Todos: %s | Sessions: %d | Last: %s\n' "$todos_str" "$fsessions_count" "$ago_str"
    [ -n "$fle" ] && printf '   最後：%s\n' "$fle"
    printf '\n'
  done

  # Ungrouped
  if [ -n "$ungrouped_json" ]; then
    local ug_count
    ug_count=$(echo "$ungrouped_json" | jq '.sessions | length')
    if [ "$ug_count" -gt 0 ]; then
      printf '\033[1mUngrouped Sessions (%d)\033[0m\n' "$ug_count"
      local -a ug_sids
      mapfile -t ug_sids < <(echo "$ungrouped_json" | jq -r '.sessions[]')
      for ug_sid in "${ug_sids[@]}"; do
        local ug_file
        ug_file=$(find "$HOME/.claude/projects" -name "${ug_sid}*.jsonl" -type f 2>/dev/null | head -1)
        if [ -n "$ug_file" ]; then
          local ug_topic ug_ago ug_mod ug_now
          ug_topic=$(_ccs_topic_from_jsonl "$ug_file")
          ug_mod=$(stat -c "%Y" "$ug_file" 2>/dev/null)
          ug_now=$(date +%s)
          ug_ago=$(( (ug_now - ug_mod) / 60 ))
          printf '   \033[90m%s\033[0m  %s (%s)\n' "$ug_sid" "$ug_topic" "$(_ccs_ago_str "$ug_ago")"
        fi
      done
      printf '\n'
    fi
  fi
}

# Detail view for a specific feature
_ccs_feature_detail_md() {
  local feature_name="$1" git_commits="${2:-3}"
  local data_dir
  data_dir=$(_ccs_data_dir)
  local features_file="${data_dir}/features.jsonl"
  [ ! -f "$features_file" ] && { echo "No features found."; return 1; }

  # Find matching feature (partial match on id)
  local feature_line=""
  while IFS= read -r line; do
    local fid
    fid=$(echo "$line" | jq -r '.id')
    [ "$fid" = "_ungrouped" ] && continue
    if [[ "$fid" == *"$feature_name"* ]]; then
      feature_line="$line"
      break
    fi
  done < "$features_file"

  [ -z "$feature_line" ] && { echo "Feature '$feature_name' not found."; return 1; }

  local fid flabel fproject fbranch fstatus ftd ftt fle fgd
  fid=$(echo "$feature_line" | jq -r '.id')
  flabel=$(echo "$feature_line" | jq -r '.label')
  fproject=$(echo "$feature_line" | jq -r '.project')
  fbranch=$(echo "$feature_line" | jq -r '.branch // ""')
  fstatus=$(echo "$feature_line" | jq -r '.status')
  ftd=$(echo "$feature_line" | jq -r '.todos_done')
  ftt=$(echo "$feature_line" | jq -r '.todos_total')
  fle=$(echo "$feature_line" | jq -r '.last_exchange // ""')
  fgd=$(echo "$feature_line" | jq -r '.git_dirty')

  printf '## %s\n' "$flabel"
  printf -- '- **專案：** %s\n' "$fproject"
  [ -n "$fbranch" ] && printf -- '- **Branch：** %s\n' "$fbranch"
  printf -- '- **狀態：** %s\n' "$fstatus"

  # Todos detail
  local pending_count=$((ftt - ftd))
  if [ "$ftt" -gt 0 ]; then
    if [ "$ftd" -eq "$ftt" ]; then
      printf -- '- **Todos：** %d/%d 完成 ✓\n' "$ftd" "$ftt"
    else
      printf -- '- **Todos：** %d/%d 完成，剩 %d pending\n' "$ftd" "$ftt" "$pending_count"
    fi
    # Show pending todos from sessions
    local -a session_sids
    mapfile -t session_sids < <(echo "$feature_line" | jq -r '.sessions[]')
    for sid in "${session_sids[@]}"; do
      local sfile
      sfile=$(find "$HOME/.claude/projects" -name "${sid}*.jsonl" -type f 2>/dev/null | head -1)
      [ -z "$sfile" ] && continue
      local sdata
      sdata=$(_ccs_overview_session_data "$sfile")
      [ -z "$sdata" ] && continue
      echo "$sdata" | jq -r '.todos[] | select(.status != "completed") | "  - [ ] " + .content' 2>/dev/null
    done
  else
    printf -- '- **Todos：** (none)\n'
  fi

  # Git status
  local proj_path=""
  local first_sid
  first_sid=$(echo "$feature_line" | jq -r '.sessions[0] // ""')
  if [ -n "$first_sid" ]; then
    local first_file
    first_file=$(find "$HOME/.claude/projects" -name "${first_sid}*.jsonl" -type f 2>/dev/null | head -1)
    if [ -n "$first_file" ]; then
      local encoded_dir
      encoded_dir=$(basename "$(dirname "$first_file")")
      proj_path=$(_ccs_resolve_project_path "$encoded_dir")
    fi

    if [ -n "$proj_path" ] && [ -d "$proj_path/.git" ]; then
      local branch
      branch=$(git -C "$proj_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
      printf -- '- **Git：** %s' "$branch"
      [ "$fgd" -gt 0 ] && printf ' (%d uncommitted files)' "$fgd"
      printf '\n'

      # Recent commits
      if [ "$git_commits" -gt 0 ]; then
        printf -- '- **Recent Commits:**\n'
        git -C "$proj_path" log --oneline --format="  - %h %ar — %s" -"$git_commits" 2>/dev/null
      fi
    fi
  fi

  # Sessions table
  local -a session_sids2
  mapfile -t session_sids2 < <(echo "$feature_line" | jq -r '.sessions[]')
  local scount=${#session_sids2[@]}
  printf -- '- **Sessions (%d)：**\n' "$scount"
  printf '  | # | Session | Topic | Last Active |\n'
  printf '  |---|---------|-------|-------------|\n'
  local sn=0
  for sid in "${session_sids2[@]}"; do
    sn=$((sn + 1))
    local sfile
    sfile=$(find "$HOME/.claude/projects" -name "${sid}*.jsonl" -type f 2>/dev/null | head -1)
    if [ -n "$sfile" ]; then
      local stopic smod snow sago
      stopic=$(_ccs_topic_from_jsonl "$sfile")
      smod=$(stat -c "%Y" "$sfile" 2>/dev/null)
      snow=$(date +%s)
      sago=$(( (snow - smod) / 60 ))
      printf '  | %d | %s | %s | %s |\n' "$sn" "$sid" "$stopic" "$(_ccs_ago_str "$sago")"
    fi
  done

  # Last exchange
  [ -n "$fle" ] && printf -- '- **最後進展：** %s\n' "$fle"
}

# Timeline view for a specific feature
_ccs_feature_timeline_md() {
  local feature_name="$1" git_commits="${2:-3}"
  local data_dir
  data_dir=$(_ccs_data_dir)
  local features_file="${data_dir}/features.jsonl"
  [ ! -f "$features_file" ] && { echo "No features found."; return 1; }

  # Find matching feature
  local feature_line=""
  while IFS= read -r line; do
    local fid
    fid=$(echo "$line" | jq -r '.id')
    [ "$fid" = "_ungrouped" ] && continue
    if [[ "$fid" == *"$feature_name"* ]]; then
      feature_line="$line"
      break
    fi
  done < "$features_file"

  [ -z "$feature_line" ] && { echo "Feature '$feature_name' not found."; return 1; }

  local flabel
  flabel=$(echo "$feature_line" | jq -r '.label')
  printf '## %s — Timeline\n\n' "$flabel"

  # Collect session info with timestamps, then sort by time
  local -a session_sids
  mapfile -t session_sids < <(echo "$feature_line" | jq -r '.sessions[]')

  # Build sortable entries: timestamp\tsid\tfile
  local -a entries=()
  for sid in "${session_sids[@]}"; do
    local sfile
    sfile=$(find "$HOME/.claude/projects" -name "${sid}*.jsonl" -type f 2>/dev/null | head -1)
    [ -z "$sfile" ] && continue
    local smod
    smod=$(stat -c "%Y" "$sfile" 2>/dev/null)
    entries+=("${smod}\t${sid}\t${sfile}")
  done

  # Sort by timestamp descending (most recent first)
  local sorted
  sorted=$(printf '%b\n' "${entries[@]}" | sort -rn)

  while IFS=$'\t' read -r ts sid sfile; do
    [ -z "$sfile" ] && continue
    local datetime stopic
    datetime=$(date -d "@$ts" "+%Y-%m-%d %H:%M" 2>/dev/null)
    stopic=$(_ccs_topic_from_jsonl "$sfile")

    printf '### %s — %s %s\n' "$datetime" "$sid" "$stopic"

    # Last user/claude exchange
    local sdata
    sdata=$(_ccs_overview_session_data "$sfile")
    if [ -n "$sdata" ]; then
      local user_text asst_text
      user_text=$(echo "$sdata" | jq -r '.last_exchange.user // ""' | head -1 | cut -c1-120)
      asst_text=$(echo "$sdata" | jq -r '.last_exchange.assistant // ""' | head -1 | cut -c1-200)
      [ -n "$user_text" ] && printf '  User: %s\n' "$user_text"
      [ -n "$asst_text" ] && printf '  Claude: %s\n' "$asst_text"

      # Todos summary
      local td tt
      td=$(echo "$sdata" | jq '[.todos[] | select(.status == "completed")] | length')
      tt=$(echo "$sdata" | jq '.todos | length')
      if [ "$tt" -gt 0 ]; then
        if [ "$td" -eq "$tt" ]; then
          printf '  (todos: %d/%d ✓)\n' "$td" "$tt"
        else
          printf '  (todos: %d/%d)\n' "$td" "$tt"
        fi
      fi
    fi
    printf '\n'
  done <<< "$sorted"
}

# Entry point
ccs-feature() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-feature  — feature progress tracking
[personal tool, not official Claude Code]

Usage:
  ccs-feature              Terminal ANSI output (default)
  ccs-feature --md         Markdown output (for Skill / Happy web)
  ccs-feature --json       JSON output (for Skill structured parsing)
  ccs-feature <name>       Detail view for a specific feature
  ccs-feature <name> --timeline   Timeline view
  ccs-feature <name> -n N  Show N git commits in detail view (default: 3)
HELP
    return 0
  fi

  local mode="terminal" feature_name="" timeline=false git_commits=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --md)         mode="md"; shift ;;
      --json)       mode="json"; shift ;;
      --timeline)   timeline=true; shift ;;
      -n)           git_commits="${2:-3}"; shift; [ $# -gt 0 ] && shift ;;
      -*)           echo "Unknown option: $1" >&2; return 1 ;;
      *)            feature_name="$1"; shift ;;
    esac
  done

  # Collect sessions and run clustering
  local -a session_files=() session_projects=() session_rows=()
  _ccs_collect_sessions session_files session_projects session_rows
  _ccs_feature_cluster session_files session_projects session_rows

  if [ -n "$feature_name" ]; then
    # Detail or timeline view (Task 3)
    if $timeline; then
      case "$mode" in
        md|terminal) _ccs_feature_timeline_md "$feature_name" "$git_commits" ;;
        json)        _ccs_feature_json | jq --arg fn "$feature_name" '[.[] | select(.id | contains($fn))]' ;;
      esac
    else
      case "$mode" in
        md|terminal) _ccs_feature_detail_md "$feature_name" "$git_commits" ;;
        json)        _ccs_feature_json | jq --arg fn "$feature_name" '[.[] | select(.id | contains($fn))]' ;;
      esac
    fi
  else
    # Summary view
    case "$mode" in
      md)       _ccs_feature_md ;;
      json)     _ccs_feature_json ;;
      terminal) _ccs_feature_terminal ;;
    esac
  fi
}

# ── ccs-tag — manual session-to-feature assignment ──
ccs-tag() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-tag  — manual session-to-feature assignment
[personal tool, not official Claude Code]

Usage:
  ccs-tag <session-prefix> <feature-id>           Assign session to feature
  ccs-tag --exclude <session-prefix> <feature-id>  Exclude session from feature
  ccs-tag --list                                    List all overrides
  ccs-tag --clear <session-prefix>                  Remove all overrides for session
  ccs-tag --clear <session-prefix> <feature-id>     Remove specific override
HELP
    return 0
  fi

  local data_dir
  data_dir=$(_ccs_data_dir)
  local overrides_file="${data_dir}/overrides.jsonl"

  case "${1:-}" in
    --list)
      if [ ! -f "$overrides_file" ] || [ ! -s "$overrides_file" ]; then
        echo "No overrides."
        return 0
      fi
      printf '%-10s %-30s %s\n' "SESSION" "FEATURE" "ACTION"
      printf '%-10s %-30s %s\n' "-------" "-------" "------"
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        local s f a
        s=$(echo "$line" | jq -r '.session // ""')
        f=$(echo "$line" | jq -r '.feature // ""')
        a=$(echo "$line" | jq -r '.action // ""')
        printf '%-10s %-30s %s\n' "$s" "$f" "$a"
      done < "$overrides_file"
      ;;

    --exclude)
      shift
      local session_prefix="$1" feature_id="$2"
      [ -z "$session_prefix" ] || [ -z "$feature_id" ] && {
        echo "Usage: ccs-tag --exclude <session-prefix> <feature-id>" >&2
        return 1
      }
      # Validate session exists
      local found
      found=$(find "$HOME/.claude/projects" -name "${session_prefix}*.jsonl" -type f 2>/dev/null | head -1)
      [ -z "$found" ] && { echo "Session '$session_prefix' not found." >&2; return 1; }

      jq -nc --arg s "$session_prefix" --arg f "$feature_id" \
        '{"session":$s, "feature":$f, "action":"exclude"}' >> "$overrides_file"
      echo "Excluded $session_prefix from $feature_id"
      ;;

    --clear)
      shift
      local session_prefix="$1" feature_id="${2:-}"
      [ -z "$session_prefix" ] && {
        echo "Usage: ccs-tag --clear <session-prefix> [feature-id]" >&2
        return 1
      }
      [ ! -f "$overrides_file" ] && { echo "No overrides to clear."; return 0; }

      local tmp_file
      tmp_file=$(mktemp "${data_dir}/overrides.tmp.XXXXXX")

      if [ -n "$feature_id" ]; then
        # Remove specific override
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          local s f
          s=$(echo "$line" | jq -r '.session // ""')
          f=$(echo "$line" | jq -r '.feature // ""')
          if [[ "$s" == "$session_prefix" ]] && [[ "$f" == "$feature_id" ]]; then
            continue
          fi
          echo "$line"
        done < "$overrides_file" > "$tmp_file"
        echo "Cleared override: $session_prefix → $feature_id"
      else
        # Remove all overrides for session
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          local s
          s=$(echo "$line" | jq -r '.session // ""')
          [[ "$s" == "$session_prefix" ]] && continue
          echo "$line"
        done < "$overrides_file" > "$tmp_file"
        echo "Cleared all overrides for $session_prefix"
      fi

      mv "$tmp_file" "$overrides_file"
      ;;

    "")
      echo "Usage: ccs-tag <session-prefix> <feature-id>" >&2
      echo "       ccs-tag --help for more options" >&2
      return 1
      ;;

    -*)
      echo "Unknown option: $1" >&2
      return 1
      ;;

    *)
      # Default: assign
      local session_prefix="$1" feature_id="$2"
      [ -z "$feature_id" ] && {
        echo "Usage: ccs-tag <session-prefix> <feature-id>" >&2
        return 1
      }
      # Validate session exists
      local found
      found=$(find "$HOME/.claude/projects" -name "${session_prefix}*.jsonl" -type f 2>/dev/null | head -1)
      [ -z "$found" ] && { echo "Session '$session_prefix' not found." >&2; return 1; }

      jq -nc --arg s "$session_prefix" --arg f "$feature_id" \
        '{"session":$s, "feature":$f, "action":"assign"}' >> "$overrides_file"
      echo "Assigned $session_prefix → $feature_id"
      ;;
  esac
}

# ── ccs-crash helpers ──
_ccs_crash_md() {
  local -n _map=$1 _files=$2 _projects=$3 _rows=$4

  local boot_epoch
  boot_epoch=$(_ccs_get_boot_epoch) || boot_epoch=0
  local boot_str="unknown"
  [ "$boot_epoch" -gt 0 ] && boot_str=$(date -d "@$boot_epoch" '+%Y-%m-%d %H:%M')

  printf '## %s Crash-Interrupted Sessions (boot: %s)\n' "⚠️" "$boot_str"
  echo ""

  local count=${#_files[@]}
  local i
  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local sid=$(basename "$f" .jsonl)
    [ -n "${_map[$sid]+x}" ] || continue

    local conf_path="${_map[$sid]}"
    local confidence="${conf_path%%:*}"
    local path="${conf_path#*:}"
    local icon="🔴"
    [ "$confidence" = "low" ] && icon="🟡"

    local row="${_rows[$i]}"
    local project=$(echo "$row" | cut -f1)
    local ago_min=$(echo "$row" | cut -f2)
    local topic=$(_ccs_topic_from_jsonl "$f")

    # Session data (last message, todos, git)
    local data
    data=$(_ccs_overview_session_data "$f")
    local last_user
    last_user=$(echo "$data" | jq -r '.last_exchange.user // "(none)"' 2>/dev/null)

    local todo_summary=""
    local todo_count=$(echo "$data" | jq '[.todos[]?] | length' 2>/dev/null)
    local todo_done=$(echo "$data" | jq '[.todos[]? | select(.status == "completed")] | length' 2>/dev/null)
    [ "${todo_count:-0}" -gt 0 ] && todo_summary="${todo_done}/${todo_count}"

    # Git info
    local dir="${_projects[$i]}"
    local resolved_path
    resolved_path=$(_ccs_resolve_project_path "$dir" 2>/dev/null) || resolved_path=""
    local git_branch="" git_dirty=0
    if [ -n "$resolved_path" ] && [ -d "$resolved_path/.git" ]; then
      git_branch=$(git -C "$resolved_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
      git_dirty=$(git -C "$resolved_path" status --porcelain 2>/dev/null | wc -l)
    fi

    local mtime=$(stat -c "%Y" "$f" 2>/dev/null)
    local last_time=$(date -d "@$mtime" '+%H:%M' 2>/dev/null)

    echo "### $icon ${sid:0:8} — $project — $topic"
    echo "- **Confidence:** $confidence ($path)"
    echo "- **最後活動：** $last_time（${ago_min}m ago）"
    echo "- **最後訊息：** $last_user"
    [ -n "$todo_summary" ] && echo "- **Todos：** $todo_summary"
    [ -n "$git_branch" ] && echo "- **Git：** $git_branch ($git_dirty uncommitted files)"
    echo "- **Resume：** \`claude --resume $sid\`"
    echo "- **Detail：** \`ccs-session ${sid:0:8}\`"
    echo ""
  done

  echo "---"
  echo "cleanup: \`ccs-crash --clean\` (interactive) | \`ccs-crash --clean-all\` (batch)"
}

_ccs_crash_json() {
  local -n _map=$1 _files=$2 _projects=$3 _rows=$4
  local reboot_window="${5:-30}" idle_window="${6:-1440}"

  local boot_epoch
  boot_epoch=$(_ccs_get_boot_epoch) || boot_epoch=0
  local boot_iso="null"
  [ "$boot_epoch" -gt 0 ] && boot_iso="\"$(date -d "@$boot_epoch" --iso-8601=seconds)\""

  local tmpdir="${BASH_SOURCE[0]%/*}/tmp"
  mkdir -p "$tmpdir"
  local tmpf="$tmpdir/.crash-sessions.jsonl"
  : > "$tmpf"  # truncate

  local count=${#_files[@]}
  local i
  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local sid=$(basename "$f" .jsonl)
    [ -n "${_map[$sid]+x}" ] || continue

    local conf_path="${_map[$sid]}"
    local confidence="${conf_path%%:*}"
    local detection_path="${conf_path#*:}"

    local row="${_rows[$i]}"
    local project=$(echo "$row" | cut -f1)
    local topic=$(_ccs_topic_from_jsonl "$f")

    local data
    data=$(_ccs_overview_session_data "$f")
    local last_user
    last_user=$(echo "$data" | jq -r '.last_exchange.user // ""' 2>/dev/null)
    local todos
    todos=$(echo "$data" | jq '[.todos[]?]' 2>/dev/null)

    local dir="${_projects[$i]}"
    local resolved_path
    resolved_path=$(_ccs_resolve_project_path "$dir" 2>/dev/null) || resolved_path=""
    local git_branch="" git_dirty=0
    if [ -n "$resolved_path" ] && [ -d "$resolved_path/.git" ]; then
      git_branch=$(git -C "$resolved_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
      git_dirty=$(git -C "$resolved_path" status --porcelain 2>/dev/null | wc -l)
    fi

    local mtime=$(stat -c "%Y" "$f" 2>/dev/null)
    local last_iso=$(date -d "@$mtime" --iso-8601=seconds 2>/dev/null)

    jq -nc \
      --arg sid "$sid" \
      --arg conf "$confidence" \
      --arg dpath "$detection_path" \
      --arg proj "$project" \
      --arg topic "$topic" \
      --arg last_act "$last_iso" \
      --arg last_msg "$last_user" \
      --argjson todos "${todos:-[]}" \
      --arg git_br "$git_branch" \
      --argjson git_d "$git_dirty" \
      --arg resume "claude --resume $sid" \
      '{
        session_id: $sid[0:8],
        session_uuid: $sid,
        confidence: $conf,
        detection_path: $dpath,
        project: $proj,
        topic: $topic,
        last_activity: $last_act,
        last_user_message: $last_msg,
        todos: $todos,
        git: {branch: $git_br, uncommitted_files: $git_d},
        resume_command: $resume
      }' >> "$tmpf"
  done

  jq -nc \
    --argjson boot "$boot_iso" \
    --argjson rw "$reboot_window" \
    --argjson iw "$idle_window" \
    --argjson sessions "$(jq -sc '.' "$tmpf")" \
    '{boot_time: $boot, reboot_window_minutes: $rw, idle_window_minutes: $iw, sessions: $sessions}'

  rm -f "$tmpf"
}

# ── ccs-crash: archive helper ──
# Write last-prompt marker to JSONL to mark session as archived.
_ccs_archive_session() {
  local f="$1"
  [ -f "$f" ] || return 1
  printf '{"type":"last-prompt"}\n' >> "$f"
}

# ── ccs-crash: interactive cleanup ──
_ccs_crash_clean() {
  local -n _map=$1 _files=$2 _projects=$3 _rows=$4
  local count=${#_files[@]}
  local archived=0 skipped=0 total=0

  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local sid=$(basename "$f" .jsonl)
    [ -n "${_map[$sid]+x}" ] || continue
    total=$((total + 1))

    local conf_path="${_map[$sid]}"
    local row="${_rows[$i]}"
    local project=$(echo "$row" | cut -f1)
    local topic=$(_ccs_topic_from_jsonl "$f")

    printf '\n\033[1m[%d/%d]\033[0m \033[31m%s\033[0m — %s\n' \
      "$total" "${#_map[@]}" "${sid:0:8}" "$project"
    printf '  Topic: %s\n' "$topic"
    printf '  Type:  %s\n' "$conf_path"

    printf '  \033[33m(a)\033[0mrchive  \033[33m(s)\033[0mkip  \033[33m(q)\033[0muit? '
    local choice
    read -r -n1 choice
    echo ""

    case "$choice" in
      a|A)
        _ccs_archive_session "$f"
        printf '  \033[32m✓ Archived\033[0m\n'
        archived=$((archived + 1))
        ;;
      q|Q)
        printf '  Quit.\n'
        break
        ;;
      *)
        printf '  Skipped.\n'
        skipped=$((skipped + 1))
        ;;
    esac
  done

  printf '\n\033[1mDone:\033[0m %d archived, %d skipped, %d total\n' "$archived" "$skipped" "${#_map[@]}"
}

# ── ccs-crash: batch cleanup ──
_ccs_crash_clean_all() {
  local -n _map=$1 _files=$2
  local count=${#_files[@]}
  local archived=0

  printf 'Archiving %d crashed sessions...\n' "${#_map[@]}"

  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local sid=$(basename "$f" .jsonl)
    [ -n "${_map[$sid]+x}" ] || continue

    _ccs_archive_session "$f"
    printf '  ✓ %s\n' "${sid:0:8}"
    archived=$((archived + 1))
  done

  printf '\n\033[1mDone:\033[0m %d sessions archived.\n' "$archived"
}

# ── ccs-crash — detect sessions interrupted by crash or unexpected reboot ──
ccs-crash() {
  local mode="md" reboot_window=30 idle_window=1440 show_all=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --reboot-window) reboot_window="$2"; shift 2 ;;
      --idle-window)   idle_window="$2"; shift 2 ;;
      --md)            mode="md"; shift ;;
      --json)          mode="json"; shift ;;
      --all|-a)        show_all=true; shift ;;
      --clean)         mode="clean"; shift ;;
      --clean-all)     mode="clean-all"; shift ;;
      --help|-h)
        cat <<'HELP'
ccs-crash  — detect sessions interrupted by crash or unexpected reboot
[personal tool, not official Claude Code]

Usage:
  ccs-crash                  Markdown output, high confidence only (default)
  ccs-crash --json           JSON output
  ccs-crash --all            Include low confidence + subagent sessions
  ccs-crash --clean          Interactive cleanup (archive crashed sessions one by one)
  ccs-crash --clean-all      Archive all high-confidence crashed sessions at once
  ccs-crash --reboot-window N  Path 1 window in minutes (default: 30)
  ccs-crash --idle-window N    Path 2 window in minutes (default: 1440)

Detection paths:
  Path 1 (reboot):     mtime in [boot_time - window, boot_time + 120s)
  Path 2 (non-reboot): dead process + JSONL interrupt signal analysis

Confidence levels:
  high  Reboot-window match OR explicit interrupt signal (no text in last response)
  low   Dead process but last response has text (could be manual Ctrl+C)
HELP
        return 0 ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  # Collect sessions (include subagents if --all)
  local -a session_files=() session_projects=() session_rows=()
  _ccs_collect_sessions $($show_all && echo "--all") session_files session_projects session_rows

  # Run detection
  local -A crash_map=()
  _ccs_detect_crash crash_map --reboot-window "$reboot_window" --idle-window "$idle_window" session_files session_projects

  # Filter low confidence unless --all
  if ! $show_all; then
    for sid in "${!crash_map[@]}"; do
      [[ "${crash_map[$sid]}" == low:* ]] && unset 'crash_map[$sid]'
    done
  fi

  if [ ${#crash_map[@]} -eq 0 ]; then
    echo "No crash-interrupted sessions detected."
    return 0
  fi

  case "$mode" in
    md)        _ccs_crash_md crash_map session_files session_projects session_rows ;;
    json)      _ccs_crash_json crash_map session_files session_projects session_rows "$reboot_window" "$idle_window" ;;
    clean)     _ccs_crash_clean crash_map session_files session_projects session_rows ;;
    clean-all) _ccs_crash_clean_all crash_map session_files ;;
  esac
}

# ── ccs-overview — cross-session work overview ──
ccs-overview() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-overview  — cross-session work overview
[personal tool, not official Claude Code]

Usage:
  ccs-overview              Terminal ANSI output (default, excludes subagents)
  ccs-overview --all        Include subagent sessions
  ccs-overview --md         Markdown output (for Skill / Happy web)
  ccs-overview --json       JSON output (for Skill structured parsing)
  ccs-overview --git        Cross-project git status
  ccs-overview --git -n N   Show N recent commits (default: 3)
  ccs-overview --files      Cross-session file operations (E/W only)
  ccs-overview --files --all-ops  Include Read operations
  ccs-overview --todos-only Cross-session pending todos only
HELP
    return 0
  fi

  local mode="terminal" todos_only=false git_mode=false files_mode=false show_all=false git_commits=3 all_ops=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --md)         mode="md"; shift ;;
      --json)       mode="json"; shift ;;
      --git)        git_mode=true; shift ;;
      --files)      files_mode=true; shift ;;
      --all-ops)    all_ops=true; shift ;;
      --todos-only) todos_only=true; shift ;;
      --all|-a)     show_all=true; shift ;;
      -n)           git_commits="${2:-3}"; shift; [ $# -gt 0 ] && shift ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  # Collect active sessions
  local -a session_files=() session_projects=() session_rows=()
  _ccs_collect_sessions $($show_all && echo "--all") session_files session_projects session_rows

  local session_count=${#session_files[@]}

  # Crash detection (high confidence only, for overview banner)
  local -A crash_map=()
  _ccs_detect_crash crash_map session_files session_projects

  if $git_mode; then
    _ccs_overview_git session_files session_projects "$mode" "$git_commits"
    return $?
  fi

  if $files_mode; then
    _ccs_overview_files session_files session_projects "$mode" "$all_ops"
    return $?
  fi

  if $todos_only; then
    _ccs_overview_todos session_files session_projects session_rows "$mode"
    return $?
  fi

  # Full overview
  case "$mode" in
    md)       _ccs_overview_md session_files session_projects session_rows crash_map ;;
    json)     _ccs_overview_json session_files session_projects session_rows crash_map ;;
    terminal) _ccs_overview_terminal session_files session_projects session_rows crash_map ;;
  esac
}

# _ccs_detect_last_workday — 找上次有 session 活動的日期
# 輸出: epoch timestamp (該日 00:00)
# 邏輯: 掃描所有 JSONL mtime，從昨天往回找第一個有活動的日期
_ccs_detect_last_workday() {
  local claude_dir="$HOME/.claude/projects"
  [ -d "$claude_dir" ] || { date -d "yesterday 00:00" +%s; return; }

  local today_start
  today_start=$(date -d "today 00:00" +%s)

  # 收集所有 JSONL 的 mtime，轉為日期（只取 YYYY-MM-DD），去重排序
  local -A active_dates=()
  local day_start day_epoch
  while IFS= read -r mtime; do
    day_start=$(date -d "@$mtime" +%Y-%m-%d 2>/dev/null) || continue
    day_epoch=$(date -d "$day_start 00:00" +%s 2>/dev/null) || continue
    # 跳過今天
    (( day_epoch >= today_start )) && continue
    active_dates["$day_start"]=$day_epoch
  done < <(find "$claude_dir" -name "*.jsonl" -printf "%T@\n" 2>/dev/null)

  if [ ${#active_dates[@]} -eq 0 ]; then
    # 無任何歷史 session，fallback 到昨天
    date -d "yesterday 00:00" +%s
    return
  fi

  # 取最近的日期
  local latest_epoch=0
  for ep in "${active_dates[@]}"; do
    (( ep > latest_epoch )) && latest_epoch=$ep
  done
  echo "$latest_epoch"
}

# _ccs_recap_scan_projects — 列出有活動的專案目錄名
# $1: from_epoch (起始時間)
# 輸出: 每行一個專案目錄名（~/.claude/projects/ 下的子目錄名）
_ccs_recap_scan_projects() {
  local from_epoch=${1:?missing from_epoch}
  local claude_dir="$HOME/.claude/projects"
  [ -d "$claude_dir" ] || return

  local -A seen=()
  local mtime dir
  while IFS= read -r jsonl; do
    mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || continue
    (( mtime < from_epoch )) && continue
    dir=$(dirname "$jsonl")
    dir=${dir##*/}
    [ -z "${seen[$dir]+_}" ] || continue
    seen["$dir"]=1
    echo "$dir"
  done < <(find "$claude_dir" -maxdepth 2 -name "*.jsonl" ! -path "*/subagents/*" 2>/dev/null)
}

# _ccs_recap_collect — 收集 recap 數據，輸出 JSON
# $1: from_epoch
# $2: "all" 或 "project" (專案範圍)
# $3: "true" 或 "false" (auto_detected)
_ccs_recap_collect() {
  local from_epoch=${1:?missing from_epoch}
  local scope=${2:-all}
  local auto_detected=${3:-true}
  local now_iso
  now_iso=$(date -Iseconds)
  local from_iso
  from_iso=$(date -d "@$from_epoch" -Iseconds)

  local tmpdir="${BASH_SOURCE[0]%/*}/tmp"
  mkdir -p "$tmpdir"
  local projects_tmp="$tmpdir/.recap-projects.jsonl"
  : > "$projects_tmp"

  # 收集專案列表
  local -a proj_dirs=()
  if [ "$scope" = "project" ]; then
    local cwd_encoded
    cwd_encoded=$(_ccs_resolve_jsonl "" 2>/dev/null || true)
    if [ -n "$cwd_encoded" ]; then
      proj_dirs+=("$(basename "$(dirname "$cwd_encoded")")")
    else
      echo "Error: no Claude Code sessions found for $(pwd)" >&2
      jq -n '{recap_period:{},projects:[],summary:{total_sessions:0,active:0,completed:0,todos_done:0,todos_pending:0,todos_in_progress:0}}'
      return 0
    fi
  else
    while IFS= read -r d; do
      proj_dirs+=("$d")
    done < <(_ccs_recap_scan_projects "$from_epoch")
  fi

  # 全域統計
  local total_sessions=0 active_count=0 completed_count=0
  local todos_done=0 todos_pending=0 todos_in_progress=0

  for proj_dir in "${proj_dirs[@]}"; do
    local proj_path
    proj_path=$(_ccs_resolve_project_path "$proj_dir" 2>/dev/null) || continue
    local proj_name=${proj_path##*/}
    local session_dir="$HOME/.claude/projects/$proj_dir"

    # 收集此專案在時間範圍內的 sessions
    local sessions_json="[]"
    local mtime sid topic last_iso age_min status td_done td_pending td_ip preview
    local -a pending_items=()
    while IFS= read -r jsonl; do
      mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || continue
      (( mtime < from_epoch )) && continue

      sid=$(basename "$jsonl" .jsonl)
      topic=$(_ccs_topic_from_jsonl "$jsonl")
      last_iso=$(date -d "@$mtime" -Iseconds)

      # 判斷狀態
      age_min=$(( ($(date +%s) - mtime) / 60 ))
      status="idle"
      if (( age_min < 10 )); then status="active"
      elif (( age_min < 60 )); then status="recent"
      fi
      # 檢查 archived（使用 last-prompt marker，與 ccs-core.sh 一致）
      if _ccs_is_archived "$jsonl"; then
        status="completed"
      fi

      # Todos
      td_done=0 td_pending=0 td_ip=0
      pending_items=()
      completed_items=()
      while IFS=$'\t' read -r t_status t_content; do
        case "$t_status" in
          completed)    (( td_done++ )); completed_items+=("$t_content") ;;
          pending)      (( td_pending++ )); pending_items+=("$t_content") ;;
          in_progress)  (( td_ip++ )); pending_items+=("$t_content") ;;
        esac
      done < <(jq -s -r '[.[] | select(.type == "assistant") | .message.content[]? |
        select(.type == "tool_use" and .name == "TodoWrite") |
        .input.todos] | last // [] | .[]? | [.status, .content] | @tsv' "$jsonl" 2>/dev/null)

      # Last exchange preview
      local preview=""
      preview=$(jq -r 'select(.type == "user" and .isMeta != true) |
        .message.content | if type == "string" then . else "" end |
        gsub("\n"; " ") | .[:80]' "$jsonl" 2>/dev/null | tail -1)

      # 組裝 session JSON
      local pending_json completed_json
      if [ ${#pending_items[@]} -eq 0 ]; then
        pending_json="[]"
      else
        pending_json=$(printf '%s\n' "${pending_items[@]}" | jq -R . | jq -s .)
      fi
      if [ ${#completed_items[@]} -eq 0 ]; then
        completed_json="[]"
      else
        completed_json=$(printf '%s\n' "${completed_items[@]}" | jq -R . | jq -s .)
      fi
      sessions_json=$(echo "$sessions_json" | jq \
        --arg id "$sid" \
        --arg topic "$topic" \
        --arg status "$status" \
        --arg last "$last_iso" \
        --argjson done "$td_done" \
        --argjson pend "$td_pending" \
        --argjson ip "$td_ip" \
        --argjson items "$pending_json" \
        --argjson citems "$completed_json" \
        --arg preview "$preview" \
        '. += [{
          id: $id, topic: $topic, status: $status,
          last_active: $last,
          todos: { done: ($done|tonumber), pending: ($pend|tonumber), in_progress: ($ip|tonumber) },
          pending_items: $items,
          completed_items: $citems,
          last_exchange_preview: $preview
        }]')

      (( total_sessions++ ))
      case "$status" in
        active|recent) (( active_count++ )) ;;
        completed)     (( completed_count++ )) ;;
      esac
      (( todos_done += td_done ))
      (( todos_pending += td_pending ))
      (( todos_in_progress += td_ip ))
    done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" ! -path "*/subagents/*" 2>/dev/null)

    # Features（從 features.jsonl 讀取此專案的 features）
    local data_dir
    data_dir=$(_ccs_data_dir)
    local features_json="[]"
    if [ -f "$data_dir/features.jsonl" ]; then
      features_json=$(jq -s --arg proj "$proj_dir" \
        '[.[] | select(.project == $proj) | {
          id: .id, label: .label, status: .status,
          todos: { done: .todos_done, total: .todos_total }
        }]' "$data_dir/features.jsonl" 2>/dev/null) || features_json="[]"
    fi

    # Git
    local git_json='{}'
    if [ -d "$proj_path/.git" ]; then
      local branch commits_count uncommitted unpushed
      branch=$(git -C "$proj_path" branch --show-current 2>/dev/null || echo "unknown")
      commits_count=$(git -C "$proj_path" log --after="$from_iso" --oneline 2>/dev/null | wc -l)
      uncommitted=$(git -C "$proj_path" status --porcelain 2>/dev/null | wc -l)
      unpushed=$(git -C "$proj_path" rev-list --count @{upstream}..HEAD 2>/dev/null || echo 0)
      git_json=$(jq -n \
        --arg b "$branch" \
        --argjson c "$commits_count" \
        --argjson u "$uncommitted" \
        --argjson p "$unpushed" \
        '{branch:$b, commits_in_period:$c, uncommitted:$u, unpushed:$p}')
    fi

    # Hot files（聚合 JSONL 中的 tool_use Read/Edit/Write）
    local hot_json="[]"
    unset file_edits file_reads all_hot_files 2>/dev/null
    local -A file_edits=() file_reads=()
    while IFS= read -r jsonl; do
      local mtime
      mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || continue
      (( mtime < from_epoch )) && continue
      while IFS=$'\t' read -r op fpath; do
        [ -n "$fpath" ] || continue
        fname=${fpath##*/}
        case "$op" in
          E|W) file_edits["$fname"]=$(( ${file_edits["$fname"]:-0} + 1 )) ;;
          R)   file_reads["$fname"]=$(( ${file_reads["$fname"]:-0} + 1 )) ;;
        esac
      done < <(jq -r 'select(.type == "assistant") | .message.content[]? |
        select(.type == "tool_use") |
        if .name == "Edit" then "E\t" + .input.file_path
        elif .name == "Write" then "W\t" + .input.file_path
        elif .name == "Read" then "R\t" + .input.file_path
        else empty end' "$jsonl" 2>/dev/null)
    done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" ! -path "*/subagents/*" 2>/dev/null)

    # 排序取 top 5（合併 edits + reads 的所有 key，避免遺漏只有 Read 的檔案）
    unset all_hot_files 2>/dev/null
    local -A all_hot_files=()
    for fname in "${!file_edits[@]}" "${!file_reads[@]}"; do
      all_hot_files["$fname"]=1
    done
    for fname in "${!all_hot_files[@]}"; do
      echo "$fname" "${file_edits[$fname]:-0}" "${file_reads[$fname]:-0}" \
        "$(( ${file_edits[$fname]:-0} + ${file_reads[$fname]:-0} ))"
    done | sort -k4 -rn | head -5 | while read -r fn ed rd _total; do
      jq -n --arg f "$fn" --argjson e "$ed" --argjson r "$rd" \
        '{file:$f, edits:$e, reads:$r}'
    done | jq -s '.' > "$tmpdir/.recap-hot.json"
    hot_json=$(cat "$tmpdir/.recap-hot.json" 2>/dev/null) || hot_json="[]"

    # Deadlines（從 keyword grep 掃描 user messages）
    local deadlines_json="[]"
    local dl_text
    while IFS= read -r jsonl; do
      mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || continue
      (( mtime < from_epoch )) && continue
      sid=$(basename "$jsonl" .jsonl)
      topic=$(_ccs_topic_from_jsonl "$jsonl")
      dl_text=$(jq -r 'select(.type == "user" and .isMeta != true) |
        .message.content | if type == "string" then . else "" end' "$jsonl" 2>/dev/null |
        grep -iE '(deadline|due|urgent|ASAP|月底|趕|今天|明天|後天|這週|下週|本週|by (monday|tuesday|wednesday|thursday|friday|tomorrow|end of))' |
        head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)
      if [ -n "$dl_text" ]; then
        deadlines_json=$(echo "$deadlines_json" | jq \
          --arg t "$dl_text" --arg sid "$sid" --arg topic "$topic" \
          '. += [{text:$t, session_id:$sid, session_topic:$topic}]')
      fi
    done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" ! -path "*/subagents/*" 2>/dev/null)

    # 組裝此專案的 JSON
    jq -n \
      --arg name "$proj_name" \
      --arg path "$proj_path" \
      --argjson sessions "$sessions_json" \
      --argjson features "$features_json" \
      --argjson git "$git_json" \
      --argjson hot "$hot_json" \
      --argjson deadlines "$deadlines_json" \
      '{name:$name, path:$path, sessions:$sessions,
        features:$features, git:$git,
        hot_files:$hot, deadlines:$deadlines}' >> "$projects_tmp"
  done

  # 組裝最終 JSON
  local projects_array
  projects_array=$(jq -s '.' "$projects_tmp" 2>/dev/null) || projects_array="[]"

  jq -n \
    --arg from "$from_iso" \
    --arg to "$now_iso" \
    --argjson auto "$auto_detected" \
    --argjson projects "$projects_array" \
    --argjson ts "$total_sessions" \
    --argjson ac "$active_count" \
    --argjson cc "$completed_count" \
    --argjson td "$todos_done" \
    --argjson tp "$todos_pending" \
    --argjson ti "$todos_in_progress" \
    '{
      recap_period: {from:$from, to:$to, auto_detected:$auto},
      projects: $projects,
      summary: {
        total_sessions:$ts, active:$ac, completed:$cc,
        todos_done:$td, todos_pending:$tp, todos_in_progress:$ti
      }
    }'

  rm -f "$projects_tmp" "$tmpdir/.recap-hot.json"
}

_ccs_recap_terminal() {
  local json="$1"
  local C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
  local C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m'
  local C_CYAN=$'\033[36m' C_DIM=$'\033[2m' C_WHITE=$'\033[37m'

  local from to
  from=$(echo "$json" | jq -r '.recap_period.from')
  to=$(echo "$json" | jq -r '.recap_period.to')
  local from_date
  from_date=$(date -d "$from" '+%Y-%m-%d (%a)' 2>/dev/null)

  # Header
  printf "\n${C_BOLD}${C_CYAN}╔══════════════════════════════════════════╗${C_RESET}\n"
  printf "${C_BOLD}${C_CYAN}║${C_RESET}  📋 Daily Recap — %-22s ${C_BOLD}${C_CYAN}║${C_RESET}\n" "$from_date"
  printf "${C_BOLD}${C_CYAN}║${C_RESET}  Covering: %-29s ${C_BOLD}${C_CYAN}║${C_RESET}\n" \
    "$(date -d "$from" '+%m-%d %H:%M') ~ now"
  printf "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════╝${C_RESET}\n"

  # Sessions
  local total active completed
  total=$(echo "$json" | jq '.summary.total_sessions')
  active=$(echo "$json" | jq '.summary.active')
  completed=$(echo "$json" | jq '.summary.completed')
  printf "\n${C_BOLD}── Sessions (%d active, %d completed) ──${C_RESET}\n" "$active" "$completed"

  echo "$json" | jq -r '.projects[] | .name as $proj |
    .sessions[] | [$proj, .status, .topic, .last_active] | @tsv' |
  while IFS=$'\t' read -r proj status topic last; do
    local icon age_str
    case "$status" in
      active)    icon="🟢" ;;
      recent)    icon="🟡" ;;
      completed) icon="✅" ;;
      *)         icon="💤" ;;
    esac
    local last_epoch now_epoch
    last_epoch=$(date -d "$last" +%s 2>/dev/null) || last_epoch=0
    now_epoch=$(date +%s)
    local mins=$(( (now_epoch - last_epoch) / 60 ))
    age_str=$(_ccs_ago_str "$mins")
    printf "  %s ${C_DIM}%-16s${C_RESET} %-30s ${C_DIM}%s${C_RESET}\n" \
      "$icon" "$proj" "${topic:0:30}" "$age_str"
  done

  # Todos
  local td tp ti
  td=$(echo "$json" | jq '.summary.todos_done')
  tp=$(echo "$json" | jq '.summary.todos_pending')
  ti=$(echo "$json" | jq '.summary.todos_in_progress')
  printf "\n${C_BOLD}── Todos ──${C_RESET}\n"
  printf "  ✅ Completed: ${C_GREEN}%d${C_RESET}    🔲 Pending: ${C_YELLOW}%d${C_RESET}    🔄 In Progress: ${C_CYAN}%d${C_RESET}\n" \
    "$td" "$tp" "$ti"

  # Pending items
  local has_pending
  has_pending=$(echo "$json" | jq '[.projects[].sessions[] | select(.todos.pending > 0)] | length')
  if (( has_pending > 0 )); then
    printf "\n  Pending:\n"
    echo "$json" | jq -r '.projects[] | .name as $p |
      .sessions[] | select(.todos.pending > 0) |
      .pending_items[]? | "  • [" + $p + "] " + .' |
    head -10
  fi

  # Completed items (per-project dedup, top 5 each)
  local has_completed
  has_completed=$(echo "$json" | jq '[.projects[].sessions[] | select(.todos.done > 0)] | length')
  if (( has_completed > 0 )); then
    printf "\n  Completed:\n"
    echo "$json" | jq -r '.projects[] | .name as $p |
      [.sessions[].completed_items[]?] | unique | .[:5][] |
      "  • [" + $p + "] " + .' |
    head -10
  fi

  # Features
  local feat_count
  feat_count=$(echo "$json" | jq '[.projects[].features[]] | length')
  if (( feat_count > 0 )); then
    printf "\n${C_BOLD}── Features ──${C_RESET}\n"
    echo "$json" | jq -r '.projects[].features[] |
      (if .status == "completed" then "✅"
       elif .status == "in_progress" then "🚀"
       elif .status == "stale" then "⏸️"
       else "🔧" end) + " " + .id + " " + .label +
      " [" + (.todos.done|tostring) + "/" + (.todos.total|tostring) + " todos done]"' |
    while IFS= read -r line; do
      printf "  %s\n" "$line"
    done
  fi

  # Git
  printf "\n${C_BOLD}── Git Activity ──${C_RESET}\n"
  echo "$json" | jq -r '.projects[] | select(.git.branch != null) |
    "  " + .name + " (" + .git.branch + ")  " +
    (.git.commits_in_period|tostring) + " commits, " +
    (.git.uncommitted|tostring) + " uncommitted" +
    (if .git.unpushed > 0 then ", " + (.git.unpushed|tostring) + " unpushed" else "" end)'

  # Hot files
  local hot_count
  hot_count=$(echo "$json" | jq '[.projects[].hot_files[]] | length')
  if (( hot_count > 0 )); then
    printf "\n${C_BOLD}── File Changes (top hot files) ──${C_RESET}\n"
    echo "$json" | jq -r '.projects[] | .name as $p |
      .hot_files[] | "  " + .file + "  E:" + (.edits|tostring) + " R:" + (.reads|tostring) + "  (" + $p + ")"'
  fi

  # Deadlines
  local dl_count
  dl_count=$(echo "$json" | jq '[.projects[].deadlines[]] | length')
  if (( dl_count > 0 )); then
    printf "\n${C_BOLD}${C_RED}── ⚠ Deadlines & Pending ──${C_RESET}\n"
    echo "$json" | jq -r '.projects[].deadlines[] |
      "  [" + .session_topic + "] \"" + .text + "\""'
  fi

  printf "\n"
}

_ccs_recap_md() {
  local json="$1"
  local from
  from=$(echo "$json" | jq -r '.recap_period.from')
  local from_date
  from_date=$(date -d "$from" '+%Y-%m-%d (%a)' 2>/dev/null)

  echo "# Daily Recap — $from_date"
  echo ""
  echo "Covering: $(date -d "$from" '+%m-%d %H:%M') ~ now"
  echo ""

  # Sessions
  local active completed
  active=$(echo "$json" | jq '.summary.active')
  completed=$(echo "$json" | jq '.summary.completed')
  echo "## Sessions ($active active, $completed completed)"
  echo ""
  echo "$json" | jq -r '.projects[] | .name as $p |
    .sessions[] |
    "- " + (if .status == "active" then "🟢"
            elif .status == "recent" then "🟡"
            elif .status == "completed" then "✅"
            else "💤" end) +
    " **" + $p + "** — " + .topic + " (" + .status + ")"'
  echo ""

  # Todos
  local td tp ti
  td=$(echo "$json" | jq '.summary.todos_done')
  tp=$(echo "$json" | jq '.summary.todos_pending')
  ti=$(echo "$json" | jq '.summary.todos_in_progress')
  echo "## Todos"
  echo ""
  echo "✅ Completed: $td | 🔲 Pending: $tp | 🔄 In Progress: $ti"
  echo ""
  echo "$json" | jq -r '.projects[] | .name as $p |
    .sessions[] | select(.todos.pending > 0) |
    .pending_items[]? | "- [" + $p + "] " + .'
  echo ""
  # Completed items (per-project dedup, top 5 each)
  local md_has_completed
  md_has_completed=$(echo "$json" | jq '[.projects[].sessions[] | select(.todos.done > 0)] | length')
  if (( md_has_completed > 0 )); then
    echo "**Completed highlights:**"
    echo ""
    echo "$json" | jq -r '.projects[] | .name as $p |
      [.sessions[].completed_items[]?] | unique | .[:5][] |
      "- [" + $p + "] " + .'
    echo ""
  fi

  # Features
  local feat_count
  feat_count=$(echo "$json" | jq '[.projects[].features[]] | length')
  if (( feat_count > 0 )); then
    echo "## Features"
    echo ""
    echo "$json" | jq -r '.projects[].features[] |
      "- " + (if .status == "completed" then "✅"
              elif .status == "in_progress" then "🚀"
              else "🔧" end) +
      " **" + .id + "** " + .label +
      " [" + (.todos.done|tostring) + "/" + (.todos.total|tostring) + "]"'
    echo ""
  fi

  # Git
  echo "## Git Activity"
  echo ""
  echo "$json" | jq -r '.projects[] | select(.git.branch != null) |
    "- **" + .name + "** (" + .git.branch + ") — " +
    (.git.commits_in_period|tostring) + " commits, " +
    (.git.uncommitted|tostring) + " uncommitted" +
    (if .git.unpushed > 0 then ", " + (.git.unpushed|tostring) + " unpushed" else "" end)'
  echo ""

  # Hot files
  if (( $(echo "$json" | jq '[.projects[].hot_files[]] | length') > 0 )); then
    echo "## Hot Files"
    echo ""
    echo "$json" | jq -r '.projects[] | .name as $p |
      .hot_files[] | "- `" + .file + "` E:" + (.edits|tostring) + " R:" + (.reads|tostring) + " (" + $p + ")"'
    echo ""
  fi

  # Deadlines
  if (( $(echo "$json" | jq '[.projects[].deadlines[]] | length') > 0 )); then
    echo "## ⚠ Deadlines"
    echo ""
    echo "$json" | jq -r '.projects[].deadlines[] |
      "- **" + .session_topic + ":** \"" + .text + "\""'
    echo ""
  fi
}

ccs-recap() {
  # --help
  if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    cat <<'HELP'
ccs-recap  — Daily work recap across sessions
[personal tool, not official Claude Code]

Usage:
  ccs-recap              Auto-detect last workday
  ccs-recap 2d           Last 2 days
  ccs-recap 2026-03-18   Since specific date
  ccs-recap --md         Markdown output
  ccs-recap --json       JSON output (for skill layer)
  ccs-recap --project    Current project only (default: all)
HELP
    return 0
  fi

  local mode="terminal" scope="all" time_arg=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --md)      mode="md"; shift ;;
      --json)    mode="json"; shift ;;
      --project) scope="project"; shift ;;
      *)         time_arg="$1"; shift ;;
    esac
  done

  # 解析時間範圍
  local from_epoch auto_detected=true
  if [ -z "$time_arg" ]; then
    from_epoch=$(_ccs_detect_last_workday)
  elif [[ "$time_arg" =~ ^[0-9]+d$ ]]; then
    local days=${time_arg%d}
    from_epoch=$(date -d "$days days ago 00:00" +%s)
    auto_detected=false
  elif [[ "$time_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    from_epoch=$(date -d "$time_arg 00:00" +%s)
    auto_detected=false
  else
    echo "Error: invalid time range '$time_arg' (use: 2d, 2026-03-18, or omit)" >&2
    return 1
  fi

  # 收集數據
  local json
  json=$(_ccs_recap_collect "$from_epoch" "$scope" "$auto_detected")

  # 檢查空結果
  local total
  total=$(echo "$json" | jq '.summary.total_sessions')
  if (( total == 0 )); then
    local from_date
    from_date=$(date -d "@$from_epoch" '+%Y-%m-%d')
    echo "No session activity since $from_date."
    return 0
  fi

  case "$mode" in
    md)       _ccs_recap_md "$json" ;;
    json)     echo "$json" | jq . ;;
    terminal) _ccs_recap_terminal "$json" ;;
  esac
}

# ══════════════════════════════════════════════════════════════
# ── Checkpoint: ccs-checkpoint ──
# ══════════════════════════════════════════════════════════════

# _ccs_checkpoint_parse_since — parse --since argument to epoch
# Supported: HH:MM, yesterday, Nh ago, Nm ago, ISO date, ISO datetime
# Output: epoch timestamp to stdout
_ccs_checkpoint_parse_since() {
  local input="$1"
  case "$input" in
    # HH:MM — today at that time
    [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9])
      date -d "today $input" +%s 2>/dev/null && return
      ;;
    # Nh ago / Nm ago — relative
    [0-9]*h\ ago|[0-9]*m\ ago)
      local num unit
      num="${input%%[hm] ago}"
      unit="${input#$num}"
      unit="${unit%% ago}"
      case "$unit" in
        h) date -d "$num hours ago" +%s 2>/dev/null && return ;;
        m) date -d "$num minutes ago" +%s 2>/dev/null && return ;;
      esac
      ;;
    # yesterday
    yesterday)
      date -d "yesterday 00:00" +%s 2>/dev/null && return
      ;;
    # Anything else — try date -d directly (ISO date, ISO datetime, etc.)
    *)
      date -d "$input" +%s 2>/dev/null && return
      ;;
  esac
  echo "Error: cannot parse --since '$input'" >&2
  return 1
}

# _ccs_checkpoint_collect — scan sessions, classify into 3 columns, output JSON
# $1: since_epoch
# $2: scope — "all" or "project"
_ccs_checkpoint_collect() {
  local since_epoch=${1:?missing since_epoch}
  local scope=${2:-all}
  local now_epoch
  now_epoch=$(date +%s)

  # Collect project dirs
  local -a proj_dirs=()
  if [ "$scope" = "project" ]; then
    local cwd_jsonl
    cwd_jsonl=$(_ccs_resolve_jsonl "" 2>/dev/null || true)
    if [ -n "$cwd_jsonl" ]; then
      proj_dirs+=("$(basename "$(dirname "$cwd_jsonl")")")
    else
      echo "Error: no Claude Code sessions found for $(pwd)" >&2
      jq -nc '{since:"",now:"",done:[],in_progress:[],blocked:[],summary:{total:0,done:0,in_progress:0,blocked:0}}'
      return 0
    fi
  else
    while IFS= read -r d; do
      proj_dirs+=("$d")
    done < <(_ccs_recap_scan_projects "$since_epoch")
  fi

  # Collect sessions into 3 arrays
  local done_json="[]" wip_json="[]" blocked_json="[]"

  for proj_dir in "${proj_dirs[@]}"; do
    local proj_path
    proj_path=$(_ccs_resolve_project_path "$proj_dir" 2>/dev/null) || continue
    local proj_name=${proj_path##*/}
    local session_dir="$HOME/.claude/projects/$proj_dir"

    while IFS= read -r jsonl; do
      local mtime
      mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || continue
      (( mtime < since_epoch )) && continue

      local sid topic is_archived age_min
      sid=$(basename "$jsonl" .jsonl)
      topic=$(_ccs_topic_from_jsonl "$jsonl")
      age_min=$(( (now_epoch - mtime) / 60 ))

      # Skip empty sessions (no assistant response — e.g. Happy Coder probes)
      if ! grep -qm1 '"type":"assistant"' "$jsonl" 2>/dev/null; then
        continue
      fi

      # Check archived
      is_archived=false
      if _ccs_is_archived "$jsonl"; then
        is_archived=true
      fi

      if $is_archived; then
        # Done
        done_json=$(echo "$done_json" | jq -c --arg p "$proj_name" --arg t "$topic" --arg s "$sid" \
          '. + [{project: $p, topic: $t, session: $s}]')
        continue
      fi

      # Extract todos (pending/in_progress only)
      local todos_json="[]"
      todos_json=$(jq -s -c '[.[] | select(.type == "assistant") | .message.content[]? |
        select(.type == "tool_use" and .name == "TodoWrite") |
        .input.todos] | last // [] | [.[]? | select(.status != "completed") | {status, content}]' "$jsonl" 2>/dev/null)
      [ -z "$todos_json" ] || [ "$todos_json" = "null" ] && todos_json="[]"
      local todo_count
      todo_count=$(echo "$todos_json" | jq 'length')

      # Check blocked: inactive > 2h OR keyword match
      local is_blocked=false
      if (( age_min > 120 )); then
        is_blocked=true
      else
        if jq -r 'select(.type == "user" and (.message.content | type == "string") and ((.isMeta // false) == false)) | .message.content' "$jsonl" 2>/dev/null \
          | tail -5 \
          | grep -qiE '(blocked|卡住|等待|waiting|stuck)'; then
          is_blocked=true
        fi
      fi

      local entry
      entry=$(jq -nc --arg p "$proj_name" --arg t "$topic" --arg s "$sid" \
        --argjson todos "$todos_json" --argjson tc "$todo_count" \
        '{project: $p, topic: $t, session: $s, todos: $todos, todo_count: $tc}')

      if $is_blocked; then
        blocked_json=$(echo "$blocked_json" | jq -c --argjson e "$entry" '. + [$e]')
      else
        wip_json=$(echo "$wip_json" | jq -c --argjson e "$entry" '. + [$e]')
      fi
    done < <(find "$session_dir" -maxdepth 1 -name "*.jsonl" ! -path "*/subagents/*" 2>/dev/null)
  done

  # Build result
  local d_count w_count b_count
  d_count=$(echo "$done_json" | jq 'length')
  w_count=$(echo "$wip_json" | jq 'length')
  b_count=$(echo "$blocked_json" | jq 'length')

  jq -nc \
    --arg since "$(date -d "@$since_epoch" '+%m/%d %H:%M')" \
    --arg now "$(date '+%m/%d %H:%M')" \
    --argjson done "$done_json" \
    --argjson in_progress "$wip_json" \
    --argjson blocked "$blocked_json" \
    --argjson d "$d_count" --argjson w "$w_count" --argjson b "$b_count" \
    '{
      since: $since, now: $now,
      done: $done, in_progress: $in_progress, blocked: $blocked,
      summary: {total: ($d + $w + $b), done: $d, in_progress: $w, blocked: $b}
    }'
}

# _ccs_checkpoint_terminal — render checkpoint as ANSI terminal output
# $1: JSON from _ccs_checkpoint_collect
_ccs_checkpoint_terminal() {
  local json="$1"
  local since now
  since=$(echo "$json" | jq -r '.since')
  now=$(echo "$json" | jq -r '.now')

  printf '\033[1;36m━━ Checkpoint (%s → %s) ━━\033[0m\n\n' "$since" "$now"

  # Done
  printf '\033[1;32m✅ Done\033[0m\n'
  local d_count
  d_count=$(echo "$json" | jq '.done | length')
  if (( d_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '.done[] | "  \(.project)  \(.topic)"'
  fi

  echo
  # In Progress
  printf '\033[1;33m🔄 In Progress\033[0m\n'
  local w_count
  w_count=$(echo "$json" | jq '.in_progress | length')
  if (( w_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '.in_progress[] | "  \(.project)  \(.topic)", (.todos[]? | "    - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi

  echo
  # Blocked
  printf '\033[1;31m⚠️  Blocked\033[0m\n'
  local b_count
  b_count=$(echo "$json" | jq '.blocked | length')
  if (( b_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '.blocked[] | "  \(.project)  \(.topic)", (.todos[]? | "    - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi

  echo
  local total
  total=$(echo "$json" | jq '.summary.total')
  printf '\033[90m── %d sessions · %d done · %d in progress · %d blocked ──\033[0m\n' \
    "$total" "$d_count" "$w_count" "$b_count"
}

# _ccs_checkpoint_md — render checkpoint as markdown list
# $1: JSON from _ccs_checkpoint_collect
_ccs_checkpoint_md() {
  local json="$1"
  local since now
  since=$(echo "$json" | jq -r '.since')
  now=$(echo "$json" | jq -r '.now')

  printf '## Checkpoint (%s → %s)\n\n' "$since" "$now"

  printf '### Done\n'
  local d_count
  d_count=$(echo "$json" | jq '.done | length')
  if (( d_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '.done[] | "- **\(.project)** — \(.topic)"'
  fi

  printf '\n### In Progress\n'
  local w_count
  w_count=$(echo "$json" | jq '.in_progress | length')
  if (( w_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '.in_progress[] | "- **\(.project)** — \(.topic)", (.todos[]? | "  - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi

  printf '\n### Blocked\n'
  local b_count
  b_count=$(echo "$json" | jq '.blocked | length')
  if (( b_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '.blocked[] | "- **\(.project)** — \(.topic)", (.todos[]? | "  - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi
  echo
}

# _ccs_checkpoint_table — render checkpoint as markdown table
# $1: JSON from _ccs_checkpoint_collect
_ccs_checkpoint_table() {
  local json="$1"
  local since now
  since=$(echo "$json" | jq -r '.since')
  now=$(echo "$json" | jq -r '.now')

  printf '## Checkpoint (%s → %s)\n\n' "$since" "$now"
  printf '| %s | %s | %s |\n' "狀態" "專案" "項目"
  printf '|------|------|------|\n'

  echo "$json" | jq -r '
    (.done[] | "| Done | \(.project) | \(.topic) |"),
    (.in_progress[] | "| WIP | \(.project) | \(.topic)\(if .todo_count > 0 then " (\(.todo_count) todos)" else "" end) |"),
    (.blocked[] | "| Blocked | \(.project) | \(.topic)\(if .todo_count > 0 then " (\(.todo_count) todos)" else "" end) |")
  ' 2>/dev/null

  local total
  total=$(echo "$json" | jq '.summary.total')
  (( total == 0 )) && printf '| - | - | (none) |\n'
  echo
}

# ── ccs-checkpoint [--since TIME] [--md] [--table] [--project] ──
ccs-checkpoint() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-checkpoint  — lightweight progress snapshot (Done / In Progress / Blocked)
[personal tool, not official Claude Code]

Usage:
  ccs-checkpoint                    Default: last checkpoint to now (or today 00:00)
  ccs-checkpoint --since 9:00       From today 09:00
  ccs-checkpoint --since yesterday  From yesterday 00:00
  ccs-checkpoint --since "2h ago"   From 2 hours ago
  ccs-checkpoint --md               Markdown list output
  ccs-checkpoint --md --table       Markdown table output (no todos expansion)
  ccs-checkpoint --project          Current project only
HELP
    return 0
  fi

  local since_arg="" md=false table=false scope="all" explicit_since=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --since)  [ -z "${2:-}" ] && { echo "Error: --since requires a value" >&2; return 1; }
                since_arg="$2"; explicit_since=true; shift; shift ;;
      --md)     md=true; shift ;;
      --table)  table=true; shift ;;
      --project) scope="project"; shift ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  # Resolve since_epoch
  local since_epoch
  local data_dir
  data_dir=$(_ccs_data_dir)
  local ts_file="$data_dir/last-checkpoint"

  if [ -n "$since_arg" ]; then
    since_epoch=$(_ccs_checkpoint_parse_since "$since_arg") || return 1
  elif [ -f "$ts_file" ]; then
    since_epoch=$(cat "$ts_file")
  else
    since_epoch=$(date -d "today 00:00" +%s)
  fi

  # Warn if --table without --md
  if $table && ! $md; then
    echo "Warning: --table has no effect without --md" >&2
  fi

  # Collect
  local json
  json=$(_ccs_checkpoint_collect "$since_epoch" "$scope")

  # Render
  if $md && $table; then
    _ccs_checkpoint_table "$json"
  elif $md; then
    _ccs_checkpoint_md "$json"
  else
    _ccs_checkpoint_terminal "$json"
  fi

  # Update timestamp (only when using default interval)
  if ! $explicit_since; then
    date +%s > "$ts_file"
  fi
}
