#\!/usr/bin/env bash
# ccs-overview.sh — Cross-session work overview
# Sourced by ccs-dashboard.sh — do not source directly

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
    if [ "$boot_epoch" -gt 0 ]; then
      boot_str=$(date -d "@$boot_epoch" '+%Y-%m-%d %H:%M:%S %z')
    fi
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

    # Health badge
    local health_badge
    health_badge=$(_ccs_health_badge_md "$f")

    printf '### %d. %s %s — %s %s\n' "$((i + 1))" "$emoji" "$project" "$topic" "$health_badge"
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

      # Suggested action (first pending todo)
      local first_pending
      first_pending=$(echo "$data" | jq -r '[.todos[]? | select(.status == "pending")] | .[0].content // ""')
      if [ -n "$first_pending" ]; then
        printf -- '> Suggested: dispatch "%s"\n' "${first_pending:0:80}"
      fi
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

    # Health score
    local health_json
    health_json=$(_ccs_health_events "$f" | _ccs_health_score)

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
      --argjson health "$health_json" \
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
        health: $health,
      }
      + if $c_int then {crash_interrupted: true, crash_confidence: $c_conf} else {} end
      ' >> "$sessions_tmp"

    # Add suggested_actions to the session line just appended
    local last_session
    last_session=$(tail -1 "$sessions_tmp")
    local actions
    actions=$(_ccs_dispatch_suggest_actions "$last_session")
    local augmented
    augmented=$(echo "$last_session" | jq --argjson sa "$actions" '. + {suggested_actions: $sa}' 2>/dev/null)
    if [ -n "$augmented" ]; then
      sed -i '$ d' "$sessions_tmp"
      echo "$augmented" >> "$sessions_tmp"
    fi

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
  # Expire crashes older than 3 days (consistent with ccs-status)
  local -A crash_map=()
  _ccs_detect_crash crash_map session_files session_projects
  local _now_epoch _ck _cf _cage
  _now_epoch=$(date +%s)
  for _ck in "${!crash_map[@]}"; do
    _cf=$(printf '%s\n' "${session_files[@]}" | grep "$_ck" | head -1)
    if [ -n "$_cf" ]; then
      _cage=$(( (_now_epoch - $(stat -c %Y "$_cf")) / 60 ))
      [ "$_cage" -ge 4320 ] && unset 'crash_map[$_ck]'
    fi
  done

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
