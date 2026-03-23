#\!/usr/bin/env bash
# ccs-viewer.sh — Session viewer commands (ccs-html, ccs-details)
# Sourced by ccs-dashboard.sh — do not source directly

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

