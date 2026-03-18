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
}

# ── Helper: render overview as JSON ──
# Uses temp files to avoid "Argument list too long" with many sessions.
_ccs_overview_json() {
  local -n _files=$1 _projects=$2 _rows=$3
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
        deadline_context: $data.deadline_context
      }' >> "$sessions_tmp"

    # Collect pending todos
    echo "$data" | jq -c --arg proj "$project" '.todos[]? | select(.status != "completed") | {content, status, project: $proj}' >> "$todos_tmp"
  done

  # Zombie count
  local stopped_count
  stopped_count=$(ps -eo pid,stat,comm 2>/dev/null | awk '$2 ~ /T/ && $3 ~ /claude/' | wc -l)

  # Assemble final JSON from temp files
  local sessions_arr todos_arr
  sessions_arr=$(jq -sc '.' "$sessions_tmp" 2>/dev/null || echo '[]')
  todos_arr=$(jq -sc '.' "$todos_tmp" 2>/dev/null || echo '[]')

  jq -nc \
    --arg timestamp "$now_str" \
    --argjson sessions "$sessions_arr" \
    --argjson pending_todos "$todos_arr" \
    --argjson zombie_count "$stopped_count" \
    '{
      timestamp: $timestamp,
      active_sessions: ($sessions | length),
      sessions: $sessions,
      pending_todos: $pending_todos,
      zombie_processes: $zombie_count
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

# ── Helper: render cross-project git status ──
_ccs_overview_git() {
  local -n _files=$1 _projects=$2
  local mode="$3"
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
    _ccs_overview_git_json unique_dirs
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
    printf '\n'
  done

  [ "$n" -eq 0 ] && printf '(no git repositories found)\n\n'
}

# ── Helper: git status as JSON ──
_ccs_overview_git_json() {
  local -n _dirs=$1
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

    result=$(echo "$result" | jq \
      --arg proj "$project" \
      --arg path "$resolved" \
      --arg branch "$branch" \
      --argjson dirty "$dirty" \
      --argjson ahead "$ahead" \
      --argjson behind "$behind" \
      --argjson stash "$stash_count" \
      '. + [{project: $proj, path: $path, branch: $branch, uncommitted: $dirty, ahead: $ahead, behind: $behind, stash: $stash}]')
  done

  echo "$result" | jq .
}

# ── Helper: render overview as terminal ANSI ──
_ccs_overview_terminal() {
  local -n _files=$1 _projects=$2 _rows=$3
  local count=${#_files[@]}
  local now_str
  now_str=$(date '+%Y-%m-%d %H:%M')

  printf '\033[1m── Work Overview (%s) ──\033[0m\n\n' "$now_str"

  if [ "$count" -eq 0 ]; then
    printf '  \033[90m(no active sessions)\033[0m\n\n'
    return
  fi

  printf '\033[1mActive Sessions (%d)\033[0m\n' "$count"

  local i
  for ((i = 0; i < count; i++)); do
    local f="${_files[$i]}"
    local row="${_rows[$i]}"

    local project ago_min status color
    project=$(echo "$row" | cut -f1)
    ago_min=$(echo "$row" | cut -f2)
    status=$(echo "$row" | cut -f3)
    color=$(echo "$row" | cut -f4)

    local sid
    sid=$(basename "$f" .jsonl | cut -c1-8)
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
    printf '  %b%s %-25s\033[0m \033[90m%4s\033[0m  %s\n' "$color" "$sid" "$project" "$ago_str" "$topic"

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
  ccs-overview --todos-only Cross-session pending todos only
HELP
    return 0
  fi

  local mode="terminal" todos_only=false git_mode=false show_all=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --md)         mode="md"; shift ;;
      --json)       mode="json"; shift ;;
      --git)        git_mode=true; shift ;;
      --todos-only) todos_only=true; shift ;;
      --all|-a)     show_all=true; shift ;;
      *) echo "Unknown option: $1" >&2; return 1 ;;
    esac
  done

  # Collect active sessions (non-archived, last 7 days)
  local sessions_dir="$HOME/.claude/projects"
  [ ! -d "$sessions_dir" ] && { echo "No sessions found."; return 0; }

  local -a session_files=()
  local -a session_projects=()
  local -a session_rows=()

  local cutoff
  cutoff=$(date -d "7 days ago" +%s 2>/dev/null || date -v-7d +%s 2>/dev/null)

  while IFS= read -r f; do
    local mod
    mod=$(stat -c "%Y" "$f" 2>/dev/null)
    [ "$mod" -lt "$cutoff" ] 2>/dev/null && continue

    # Skip archived
    if tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"'; then
      continue
    fi

    local dir sid_prefix
    dir=$(basename "$(dirname "$f")")
    sid_prefix=$(basename "$f" .jsonl | cut -c1-6)

    # Skip subagent sessions unless --all
    if ! $show_all; then
      # subagents project dir or agent-prefixed session ID
      [[ "$dir" == *subagents* ]] && continue
      [[ "$sid_prefix" == agent-* ]] && continue
    fi

    local row
    row=$(_ccs_session_row "$f")
    [ -z "$row" ] && continue

    session_files+=("$f")
    session_projects+=("$dir")
    session_rows+=("$row")
  done < <(find "$sessions_dir" -name "*.jsonl" -type f 2>/dev/null)

  local session_count=${#session_files[@]}

  if $git_mode; then
    _ccs_overview_git session_files session_projects "$mode"
    return $?
  fi

  if $todos_only; then
    _ccs_overview_todos session_files session_projects session_rows "$mode"
    return $?
  fi

  # Full overview
  case "$mode" in
    md)       _ccs_overview_md session_files session_projects session_rows ;;
    json)     _ccs_overview_json session_files session_projects session_rows ;;
    terminal) _ccs_overview_terminal session_files session_projects session_rows ;;
  esac
}
