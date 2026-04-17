#!/usr/bin/env bash
# ccs-dashboard.sh — Code CLI Sessions (CCS) dashboard
# Source this file from .bashrc:  source ~/tools/ccs-dashboard/ccs-dashboard.sh
#
# This is the main entry point that sources all modules:
#   ccs-core.sh      — session parsing, shared helpers, basic commands
#   ccs-health.sh    — session health scoring
#   ccs-viewer.sh    — ccs-html, ccs-details
#   ccs-handoff.sh   — ccs-handoff, ccs-resume-prompt
#   ccs-overview.sh  — ccs-overview
#   ccs-feature.sh   — ccs-feature, ccs-tag
#   ccs-ops.sh       — ccs-crash, ccs-recap, ccs-checkpoint
#   ccs-dispatch.sh  — ccs-dispatch, ccs-jobs
#
# Commands defined in this file:
#   ccs-status (ccs) — unified session dashboard
#   ccs-pick N       — show details for Nth session

# ── Load modules ──
source "$(dirname "${BASH_SOURCE[0]}")/ccs-core.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-health.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-viewer.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-handoff.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-overview.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-feature.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-ops.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-dispatch.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-review.sh"
source "$(dirname "${BASH_SOURCE[0]}")/ccs-project.sh"

# ── ccs-status (ccs) — unified session dashboard ──
ccs-status() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-status (ccs)  — unified session dashboard
[personal tool, not official Code CLI]

Sections:
  1. Active sessions   — open, non-archived (last 7 days, < 1 day old)
  2. Crashed sessions  — crash-interrupted (detected by ccs-crash logic)
  3. Zombie processes  — stopped Code CLI process (如 claude)
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

  local projects_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"

  # ── Collect data (shared by both modes) ──
  local open_files=() _status_projects=()
  local script_dir
  script_dir="$_CCS_DASHBOARD_DIR"
  local sorted_rows=""
  sorted_rows=$(python3 "$script_dir/internal/ccs_collect.py" | awk -F'|' -v max_mins="$((7 * 1440))" '
    $3 <= max_mins && $4 != "archived" { print $0 }
  ')
  while IFS='|' read -r -a cols; do
    local filepath="${cols[10]:-}"
    [ -n "$filepath" ] || continue
    open_files+=("$filepath")
    
    local prov="${cols[0]:-}"
    local proj="${cols[1]:-}"
    local resolved=""
    if [ "$prov" = "C" ]; then
      local _dname=$(basename "$(dirname "$filepath")")
      resolved=$(_ccs_resolve_project_path "$_dname" 2>/dev/null)
    else
      resolved=$(_ccs_resolve_project_path "$proj" 2>/dev/null)
    fi
    _status_projects+=("${resolved:-$proj}")
  done <<< "$sorted_rows"

  # Crash detection
  declare -A crash_map
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
    full_sid=$(basename "$f" | sed -e "s/\.jsonl$//" -e "s/\.json$//")
    if [ -n "${crash_full[$full_sid]+x}" ] && [ "$ago" -lt 10080 ]; then
      crashed_files+=("$f")
    elif [ "$ago" -lt 10080 ]; then
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
    printf "\033[1m  %-30s %-5s %-10s %-10s %s\033[0m\n" "PROJECT" "PROV" "SESSION" "ACTIVE" "TOPIC"
    for f in "${fresh_files[@]}"; do
      _ccs_session_row "$f"
    done | sort -t'|' -k2,2 -k3,3n | while IFS='|' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
      if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
        echo
      fi
      prev_project="$proj"
      
      local prov_display="[${prov}]"
      if [ "$prov" = "C" ]; then prov_display="\033[38;5;166m[C]\033[0m"; fi
      if [ "$prov" = "G" ]; then prov_display="\033[38;5;27m[G]\033[0m"; fi
      
      printf "  ${color}%-30s\033[0m %b %-10s %-10s %s%s\n" "$display_proj" "$prov_display" "$sid" "$ago_str" "$topic" " $badge"
      active_count=$((active_count + 1))
    done
  fi

  echo
  printf "\033[1;31m━━ Crashed Sessions ━━\033[0m\n"
  if [ ${#crashed_files[@]} -eq 0 ]; then
    printf "  \033[32m(none)\033[0m\n"
  else
    printf "\033[1m  %-30s %-5s %-10s %-10s %s\033[0m\n" "PROJECT" "PROV" "SESSION" "LAST ACTIVE" "TOPIC"
    for f in "${crashed_files[@]}"; do
      _ccs_session_row "$f"
    done | sort -t'|' -k2,2 -k3,3n | while IFS='|' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
      local prov_display="[${prov}]"
      if [ "$prov" = "C" ]; then prov_display="\033[38;5;166m[C]\033[0m"; fi
      if [ "$prov" = "G" ]; then prov_display="\033[38;5;27m[G]\033[0m"; fi
      
      printf "  \033[31m%-30s\033[0m %b \033[31m%-10s %-10s %s 💀\033[0m\n" "$display_proj" "$prov_display" "$sid" "$ago_str" "$topic"
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
      jsonl=$(find "$projects_dir" -maxdepth 2 \( -name "${sid}.jsonl" -o -name "${sid}.json" \) 2>/dev/null | head -1)
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
    printf "  \033[90m%d open session(s) untouched > 7 days\033[0m → \033[33mccs-sessions 168\033[0m to inspect\n" "${#stale_files[@]}"
  fi
}

# ── Helper: markdown output for ccs-status --md ──
# Usage: _ccs_status_md <list|table> <now> <fresh_files...> --- <stale_files...>
_ccs_status_md() {
  local fmt="$1"; shift
  local now="$1"; shift
  local projects_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"

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
    local sorted_rows
    sorted_rows=$(for f in "${fresh_files[@]}"; do
      _ccs_session_row "$f"
    done | sort -t'|' -k2,2 -k3,3n)


    # Table header (table mode only)
    if [ "$fmt" = "table" ]; then
      echo "| # | Project | Session | Active | Status | Topic |"
      echo "|---|---------|---------|--------|--------|-------|"
    fi

    local prev_project="" session_idx=0
    # Also build index file for ccs-pick
    local pick_file="$HOME/.claude/.ccs-pick-index"
    : > "$pick_file"

    while IFS='|' read -r prov project ago status color display_proj sid ago_str topic badge filepath; do
      session_idx=$((session_idx + 1))

      local icon
      if [ "$ago" -lt 10 ]; then
        icon="🟢"
      elif [ "$ago" -lt 60 ]; then
        icon="🟡"
      else
        icon="🔵"
      fi

      # Write to pick index: idx | sid_prefix | topic
      printf '%d\t%s\t%s\n' "$session_idx" "$sid" "$topic" >> "$pick_file"

      local prov_md=""
      if [ "$prov" = "C" ]; then prov_md="[Claude] "; fi
      if [ "$prov" = "G" ]; then prov_md="[Gemini] "; fi

      if [ "$fmt" = "table" ]; then
        local status_label
        if [ "$ago" -lt 10 ]; then status_label="active"
        elif [ "$ago" -lt 60 ]; then status_label="recent"
        else status_label="idle"; fi
        local safe_topic=$(echo "$topic" | sed 's/|/\|/g')
        local safe_project=$(echo "$project" | sed 's/|/\|/g')
        echo "| ${session_idx} | ${safe_project} | \`${sid}\` | ${ago_str} | ${icon} ${status_label} | ${prov_md}${safe_topic} |"
      else
        # List mode — group by project with header + hr
        if [ "$project" != "$prev_project" ]; then
          [ -n "$prev_project" ] && echo "---"
          local proj_count
          proj_count=$(echo "$sorted_rows" | awk -F'|' -v p="$project" '$2 == p' | wc -l)
          echo "📁 **${project}** (${proj_count})"
          echo
        fi
        prev_project="$project"
        echo "${icon} **${session_idx}.** ${prov_md}**${topic}** \`${sid}\` ${ago_str}"
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
      _ccs_session_row "$f"
    done | sort -t'|' -k2,2 -k3,3n)

    while IFS='|' read -r prov project ago status color display_proj sid ago_str topic badge filepath; do
      session_idx=$((session_idx + 1))

      printf '%d\t%s\t%s\n' "$session_idx" "$sid" "$topic" >> "$pick_file"

      local prov_md=""
      if [ "$prov" = "C" ]; then prov_md="[Claude] "; fi
      if [ "$prov" = "G" ]; then prov_md="[Gemini] "; fi

      if [ "$fmt" = "table" ]; then
        local safe_topic=$(echo "$topic" | sed 's/|/\|/g')
        local safe_project=$(echo "$project" | sed 's/|/\|/g')
        echo "| ${session_idx} | ${safe_project} | \`${sid}\` | ${ago_str} | 💀 crashed | ${prov_md}${safe_topic} |"
      else
        echo "💀 **${session_idx}.** ${prov_md}**${topic}** \`${sid}\` ${ago_str}"
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
      jsonl=$(find "$projects_dir" -maxdepth 2 \( -name "${sid}.jsonl" -o -name "${sid}.json" \) 2>/dev/null | head -1)
      [ -n "$jsonl" ] && topic=$(_ccs_topic_from_jsonl "$jsonl")
    fi

    if [ "$fmt" = "table" ]; then
      if [ "$zombie_count" -eq 1 ]; then
        echo "| PID | RAM | Working Dir | Started | Topic |"
        echo "|-----|-----|-------------|---------|-------|"
      fi
      local safe_topic=$(echo "$topic" | sed 's/|/\|/g')
      local safe_cwd=$(echo "$cwd" | sed 's/|/\|/g')
      echo "| ${pid} | ${mb} MB | ${safe_cwd} | ${started} | ${safe_topic} |"
    else
      echo "🔴 PID ${pid} · ${mb} MB · ${cwd} · ${started}"
      echo "> ${topic}"
      echo
    fi
  done < <(ps -eo pid,stat,rss,etime,args | awk '$2 ~ /^T/ && /claude/ && !/awk/')

  if ! $has_zombie; then
    echo "_(none)_ ✓"
  else
    echo "> **${zombie_count}** zombie(s), **${zombie_mb} MB** RAM → \`ccs-cleanup\` to free"
  fi
  echo

  # Stale sessions
  echo "### 💤 Stale Sessions"
  echo
  if [ ${#stale_files[@]} -eq 0 ]; then
    echo "_(none)_ ✓"
  else
    echo "> **${#stale_files[@]}** open session(s) untouched > 7 days → \`ccs-sessions 168\` to inspect"
  fi
}
alias ccs='ccs-status'

# ── ccs-pick <N> — show details for Nth session from ccs-status --md ──
ccs-pick() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-pick <N|SESSION-ID> [-n COUNT]  — show details for a session
[personal tool, not official Code CLI]

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
    full_sid=$(basename "$jsonl" | sed -e 's/\.jsonl$//' -e 's/\.json$//')
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
    local provider=$(_ccs_get_provider "$jsonl")
    local jq_filter='select(.type == "user" and (.message.content | type == "string"))'
    total_prompts=$( (
      if [ "$provider" = "gemini" ]; then
        jq -c ".[]" "$jsonl" 2>/dev/null
      else
        cat "$jsonl" 2>/dev/null
      fi
    ) | jq -c "$jq_filter" 2>/dev/null | wc -l)

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
      local provider=$(_ccs_get_provider "$jsonl")
      if [ "$provider" = "gemini" ]; then
        echo "_Resume: \`gemini --session ${full_sid}\`_"
      else
        echo "_Resume: \`claude --resume ${full_sid}\`_"
      fi
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
    local provider=$(_ccs_get_provider "$jsonl")
    if [ "$provider" = "gemini" ]; then
      echo "_Resume: \`gemini --session ${full_sid}\`_"
    else
      echo "_Resume: \`claude --resume ${full_sid}\`_"
    fi
  else
    ccs-details --last "$sid"
  fi
}
