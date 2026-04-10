#!/usr/bin/env bash
# ccs-review.sh — Session review: data extraction + report generation
# Part of ccs-dashboard. Sourced by ccs-dashboard.sh automatically.
#
# Functions:
#   _ccs_tool_use_stats          — tool use count aggregation from JSONL
#   _ccs_session_stats           — full session statistics as JSON
#   _ccs_review_json             — complete review data as JSON
#   _ccs_review_md               — render review JSON as markdown
#   _ccs_review_weekly_collect   — collect JSONL files within date range
#   _ccs_review_weekly_json      — build weekly report JSON with aggregate stats
#   _ccs_review_weekly           — weekly mode dispatcher
#   _ccs_review_weekly_md        — render weekly report JSON as markdown
#   ccs-review                   — CLI entry point
#
# Depends on ccs-core.sh helpers:
#   _ccs_resolve_jsonl, _ccs_get_pair, _ccs_build_pairs_index,
#   _ccs_topic_from_jsonl, _ccs_recent_files_md, _ccs_todos_md,
#   _ccs_data_dir

# ── Helper: count tool_use calls by tool name ──
# Output: JSON object {"Read": N, "Edit": N, ...}
_ccs_tool_use_stats() {
  local jsonl="$1"
  jq -s '
    [.[] | select(.type == "assistant") |
     .message.content[]? | select(.type == "tool_use") | .name] |
    group_by(.) | map({(.[0]): length}) | add // {}
  ' "$jsonl" 2>/dev/null
}

# ── Cache: write LLM summary ──
_ccs_review_cache_write() {
  local sid="$1" summary_json="$2"
  local cache_dir
  cache_dir="$(_ccs_data_dir)/review-cache"
  mkdir -p "$cache_dir"
  echo "$summary_json" > "$cache_dir/${sid}.summary.json"
}

# ── Cache: read LLM summary (empty string if missing/expired) ──
_ccs_review_cache_read() {
  local sid="$1" max_hours="${2:-24}"
  local cache_dir
  cache_dir="$(_ccs_data_dir)/review-cache"
  local cache_file="$cache_dir/${sid}.summary.json"

  [ -f "$cache_file" ] || return 0

  local cache_age
  cache_age=$(( ($(date +%s) - $(stat -c "%Y" "$cache_file")) / 3600 ))
  if [ "$cache_age" -lt "$max_hours" ]; then
    cat "$cache_file"
  fi
}

# ── Helper: compute full session statistics ──
# Output: JSON with rounds, duration, char_count, token_estimate, tool_use
_ccs_session_stats() {
  local jsonl="$1"

  local rounds
  rounds=$(jq -s '[.[] | select(.type == "user" and (.message.content | type == "string"))] | length' "$jsonl" 2>/dev/null)

  local first_ts last_ts
  first_ts=$(jq -r 'select(.timestamp) | .timestamp' "$jsonl" 2>/dev/null | head -1)
  last_ts=$(jq -r 'select(.timestamp) | .timestamp' "$jsonl" 2>/dev/null | tail -1)

  local duration_min=0
  if [ -n "$first_ts" ] && [ -n "$last_ts" ]; then
    local first_epoch last_epoch
    first_epoch=$(date -d "$first_ts" +%s 2>/dev/null || echo 0)
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
    duration_min=$(( (last_epoch - first_epoch) / 60 ))
  fi

  local char_count
  char_count=$(jq -s '
    [.[] |
      if .type == "user" and (.message.content | type == "string") then
        (.message.content | length)
      elif .type == "assistant" then
        ([.message.content[]? | select(.type == "text") | .text | length] | add // 0)
      else 0 end
    ] | add // 0
  ' "$jsonl" 2>/dev/null)

  local token_estimate=$(( char_count * 10 / 25 ))

  local tool_use
  tool_use=$(_ccs_tool_use_stats "$jsonl")

  jq -n \
    --argjson rounds "$rounds" \
    --arg first_ts "$first_ts" \
    --arg last_ts "$last_ts" \
    --argjson duration "$duration_min" \
    --argjson chars "$char_count" \
    --argjson tokens "$token_estimate" \
    --argjson tools "$tool_use" \
    '{
      rounds: $rounds,
      time_range: {start: $first_ts, end: $last_ts, duration_min: $duration},
      char_count: $chars,
      token_estimate: $tokens,
      tool_use: $tools
    }'
}

# ── Helper: build complete review JSON for a session ──
_ccs_review_json() {
  local jsonl="$1"
  local sid
  sid=$(basename "$jsonl" | sed -e 's/\.jsonl$//' -e 's/\.json$//')

  local dir project
  dir=$(basename "$(dirname "$jsonl")")
  project=$(_ccs_resolve_project_path "$dir" 2>/dev/null || echo "$dir")

  local model
  model=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$jsonl" 2>/dev/null | head -1)
  [ -z "$model" ] && model="unknown"

  local topic
  topic=$(_ccs_topic_from_jsonl "$jsonl")

  local stats
  stats=$(_ccs_session_stats "$jsonl")

  # Todos: extract from LAST TodoWrite call only
  local todos_json
  todos_json=$(jq -s '
    [.[] | select(.type == "assistant") |
     .message.content[]? |
     select(.type == "tool_use" and .name == "TodoWrite")] |
    if length > 0 then
      last | .input.todos | map({status: .status, content: .content})
    else [] end
  ' "$jsonl" 2>/dev/null)
  [ -z "$todos_json" ] || [ "$todos_json" = "null" ] && todos_json="[]"

  # Recent files
  local recent_files
  recent_files=$(_ccs_recent_files_md "$jsonl")
  local recent_json
  recent_json=$(echo "$recent_files" | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null)
  [ -z "$recent_json" ] && recent_json="[]"

  # Conversation pairs
  local pair_count conv_json="[]"
  pair_count=$(jq -s '[.[] | select(.type == "user" and (.message.content | type == "string"))] | length' "$jsonl" 2>/dev/null)
  if [ "$pair_count" -gt 0 ]; then
    local pairs_arr="["
    local i
    for (( i=1; i<=pair_count; i++ )); do
      local pair_data user_text asst_text tools_text
      pair_data=$(_ccs_get_pair "$jsonl" "$i")
      user_text=$(echo "$pair_data" | jq -r 'select(.role == "user") | .text' 2>/dev/null)
      asst_text=$(echo "$pair_data" | jq -r 'select(.role == "assistant") | .text' 2>/dev/null)

      # Extract tool names for this pair
      tools_text=$(jq -c '
        if .type == "user" and (.message.content | type == "string") then
          {role: "user", text: .message.content}
        elif .type == "assistant" then
          (.message.content | if type == "array" then
            [.[] | select(.type == "tool_use") |
              if .name == "Read" then "Read " + .input.file_path
              elif .name == "Edit" then "Edit " + .input.file_path
              elif .name == "Write" then "Write " + .input.file_path
              elif .name == "Bash" then "Bash: " + (.input.command | split("\n") | first | .[:60])
              elif .name == "Grep" then "Grep " + .input.pattern
              elif .name == "Agent" then "Agent: " + (.input.description // "")
              else .name end
            ] | join("\n")
          else "" end) as $tools |
          {role: "assistant", tools: $tools}
        else empty end
      ' "$jsonl" 2>/dev/null \
        | jq -sc --argjson idx "$i" '
          . as $arr |
          [to_entries[] | select(.value.role == "user")] as $users |
          if ($idx < 1 or $idx > ($users | length)) then ""
          else
            $users[$idx - 1].key as $spos |
            (if $idx < ($users | length) then $users[$idx].key else ($arr | length) end) as $epos |
            [$arr[$spos + 1 : $epos][] | select(.role == "assistant") | .tools] |
            map(select(length > 0)) | join("\n")
          end
        ')

      local tools_json
      tools_json=$(echo "$tools_text" | jq -Rs 'split("\n") | map(select(length > 0))' 2>/dev/null)

      [ "$i" -gt 1 ] && pairs_arr+=","
      pairs_arr+=$(jq -n \
        --argjson idx "$i" \
        --arg user "$user_text" \
        --arg asst "$asst_text" \
        --argjson tools "$tools_json" \
        '{index: $idx, user: $user, assistant: $asst, tools: $tools}')
    done
    pairs_arr+="]"
    conv_json="$pairs_arr"
  fi

  # LLM summary cache
  local summary="null"
  local cached_summary
  cached_summary=$(_ccs_review_cache_read "$sid")
  if [ -n "$cached_summary" ]; then
    summary="$cached_summary"
  fi

  # Git state
  local git_json='{"branch":"","recent_commits":[]}'
  if [ -d "$project" ] && [ -d "$project/.git" ]; then
    local branch recent_commits
    branch=$(git -C "$project" branch --show-current 2>/dev/null || echo "")
    recent_commits=$(git -C "$project" log --oneline -5 2>/dev/null | jq -Rs 'split("\n") | map(select(length > 0))')
    git_json=$(jq -n --arg b "$branch" --argjson c "$recent_commits" '{branch: $b, recent_commits: $c}')
  fi

  # Assemble
  jq -n \
    --arg sid "$sid" \
    --arg project "$project" \
    --arg topic "$topic" \
    --arg model "$model" \
    --argjson stats "$stats" \
    --argjson summary "$summary" \
    --argjson todos "$todos_json" \
    --argjson recent "$recent_json" \
    --argjson git "$git_json" \
    --argjson conv "$conv_json" \
    '{
      session_id: $sid,
      project: $project,
      topic: $topic,
      model: $model,
      time_range: $stats.time_range,
      stats: {
        rounds: $stats.rounds,
        char_count: $stats.char_count,
        token_estimate: $stats.token_estimate,
        tool_use: $stats.tool_use
      },
      summary: $summary,
      todos: $todos,
      recent_files: $recent,
      git_state: $git,
      conversation: $conv
    }'
}

# ── Helper: render review JSON as markdown ──
# Reads JSON from stdin, outputs markdown to stdout
_ccs_review_md() {
  local json
  json=$(cat)

  local topic project duration rounds chars tokens model
  topic=$(echo "$json" | jq -r '.topic')
  project=$(echo "$json" | jq -r '.project')
  duration=$(echo "$json" | jq -r '.time_range.duration_min')
  rounds=$(echo "$json" | jq -r '.stats.rounds')
  chars=$(echo "$json" | jq -r '.stats.char_count')
  tokens=$(echo "$json" | jq -r '.stats.token_estimate')
  model=$(echo "$json" | jq -r '.model')
  local start_time end_time
  start_time=$(echo "$json" | jq -r '.time_range.start')
  end_time=$(echo "$json" | jq -r '.time_range.end')

  cat <<EOF
# Session Review: ${topic}

- **專案：** ${project}
- **時間：** ${start_time} ~ ${end_time}（${duration} 分鐘）
- **模型：** ${model}

## 統計

- 回合數：${rounds}
- 字數：${chars}
- Token（粗估）：${tokens}

### Tool Use

EOF

  echo "$json" | jq -r '.stats.tool_use | to_entries[] | "- \(.key): \(.value) 次"'

  # LLM Summary (if present)
  local has_summary
  has_summary=$(echo "$json" | jq -r '.summary // empty')
  if [ -n "$has_summary" ] && [ "$has_summary" != "null" ]; then
    echo ""
    echo "## 完成項目"
    echo ""
    echo "$json" | jq -r '.summary.completions[]? // empty' | while IFS= read -r line; do
      echo "- ${line}"
    done
    echo ""
    echo "## 改善建議"
    echo ""
    echo "$json" | jq -r '.summary.suggestions[]? // empty' | while IFS= read -r line; do
      echo "- ${line}"
    done
  fi

  # Todos
  local todo_count
  todo_count=$(echo "$json" | jq '.todos | length')
  if [ "$todo_count" -gt 0 ]; then
    echo ""
    echo "## 任務進度"
    echo ""
    echo "$json" | jq -r '.todos[] | if .status == "completed" then "- [x] " + .content elif .status == "in_progress" then "- [~] " + .content else "- [ ] " + .content end'
  fi

  # Recent files
  local file_count
  file_count=$(echo "$json" | jq '.recent_files | length')
  if [ "$file_count" -gt 0 ]; then
    echo ""
    echo "## 涉及檔案"
    echo ""
    echo "$json" | jq -r '.recent_files[]'
  fi

  # Conversation
  local conv_count
  conv_count=$(echo "$json" | jq '.conversation | length')
  if [ "$conv_count" -gt 0 ]; then
    echo ""
    echo "## 對話紀錄"
    echo ""
    echo "$json" | jq -r '.conversation[] |
      "### [\(.index)] User\n\(.user)\n\n### [\(.index)] Claude\n\(.assistant)\n"'
  fi
}

# ── Helper: collect JSONL files within date range ──
_ccs_review_weekly_collect() {
  local since="$1" until_date="${2:-$(date +%Y-%m-%d)}"
  local projects_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"

  local since_epoch until_epoch
  since_epoch=$(date -d "$since" +%s 2>/dev/null)
  until_epoch=$(date -d "$until_date 23:59:59" +%s 2>/dev/null)

  find "$projects_dir" -maxdepth 2 -name "*.jsonl" ! -path "*/subagents/*" -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
      local mtime
      mtime=$(stat -c "%Y" "$f")
      if [ "$mtime" -ge "$since_epoch" ] && [ "$mtime" -le "$until_epoch" ]; then
        echo "$f"
      fi
    done
}

# ── Helper: build weekly report JSON ──
_ccs_review_weekly_json() {
  local since="$1" until_date="${2:-$(date +%Y-%m-%d)}"

  local -a session_jsons=()
  local total_rounds=0 total_duration=0 total_chars=0 total_tokens=0

  while IFS= read -r jsonl_file; do
    [ -z "$jsonl_file" ] && continue
    local sj
    sj=$(_ccs_review_json "$jsonl_file")
    session_jsons+=("$sj")

    total_rounds=$(( total_rounds + $(echo "$sj" | jq '.stats.rounds') ))
    total_duration=$(( total_duration + $(echo "$sj" | jq '.time_range.duration_min') ))
    total_chars=$(( total_chars + $(echo "$sj" | jq '.stats.char_count') ))
    total_tokens=$(( total_tokens + $(echo "$sj" | jq '.stats.token_estimate') ))
  done < <(_ccs_review_weekly_collect "$since" "$until_date")

  local sessions_array
  sessions_array=$(printf '%s\n' "${session_jsons[@]}" | jq -s '.')

  local tool_totals
  tool_totals=$(echo "$sessions_array" | jq '
    [.[].stats.tool_use | to_entries[]] |
    group_by(.key) | map({(.[0].key): ([.[].value] | add)}) | add // {}
  ')

  jq -n \
    --arg since "$since" \
    --arg until "$until_date" \
    --argjson total_sessions "${#session_jsons[@]}" \
    --argjson total_rounds "$total_rounds" \
    --argjson total_duration "$total_duration" \
    --argjson total_chars "$total_chars" \
    --argjson total_tokens "$total_tokens" \
    --argjson tool_totals "$tool_totals" \
    --argjson sessions "$sessions_array" \
    '{
      range: {since: $since, until: $until},
      aggregate_stats: {
        total_sessions: $total_sessions,
        total_rounds: $total_rounds,
        total_duration_min: $total_duration,
        total_char_count: $total_chars,
        total_token_estimate: $total_tokens,
        tool_use_total: $tool_totals
      },
      sessions: $sessions,
      weekly_summary: null
    }'
}

# ── Weekly mode dispatcher (called from ccs-review) ──
_ccs_review_weekly() {
  local since="$1" until_date="${2:-$(date +%Y-%m-%d)}"
  local format="${3:-md}" output_dir="$4" summarize="${5:-false}"

  local weekly_json
  weekly_json=$(_ccs_review_weekly_json "$since" "$until_date")

  case "$format" in
    json)
      echo "$weekly_json"
      ;;
    md)
      echo "$weekly_json" | _ccs_review_weekly_md
      ;;
    html)
      local slug="${since}-to-${until_date}-weekly.html"
      local outfile
      if [ -n "$output_dir" ]; then
        mkdir -p "$output_dir"
        outfile="${output_dir}/${slug}"
      else
        outfile="./${slug}"
      fi
      local script_dir="${BASH_SOURCE[0]%/*}"
      echo "$weekly_json" | python3 "${script_dir}/ccs-review-render.py" --weekly > "$outfile"
      echo "HTML written to: $outfile"
      ;;
    pdf)
      local slug="${since}-to-${until_date}-weekly.pdf"
      local outfile
      if [ -n "$output_dir" ]; then
        mkdir -p "$output_dir"
        outfile="${output_dir}/${slug}"
      else
        outfile="./${slug}"
      fi
      local script_dir="${BASH_SOURCE[0]%/*}"
      echo "$weekly_json" | python3 "${script_dir}/ccs-review-render.py" --weekly --pdf > "$outfile"
      echo "PDF written to: $outfile"
      ;;
  esac
}

# ── Weekly markdown renderer ──
_ccs_review_weekly_md() {
  local json
  json=$(cat)

  local since until_date total_sessions total_duration total_rounds total_tokens
  since=$(echo "$json" | jq -r '.range.since')
  until_date=$(echo "$json" | jq -r '.range.until')
  total_sessions=$(echo "$json" | jq '.aggregate_stats.total_sessions')
  total_duration=$(echo "$json" | jq '.aggregate_stats.total_duration_min')
  total_rounds=$(echo "$json" | jq '.aggregate_stats.total_rounds')
  total_tokens=$(echo "$json" | jq '.aggregate_stats.total_token_estimate')

  cat <<EOF
# 週報 ${since} ~ ${until_date}

## 總覽

- Session 數：${total_sessions}
- 總時間：${total_duration} 分鐘
- 總回合：${total_rounds}
- Token（粗估）：${total_tokens}

### Tool Use 合計

EOF

  echo "$json" | jq -r '.aggregate_stats.tool_use_total | to_entries[] | "- \(.key): \(.value) 次"'

  echo ""
  echo "## 各 Session 摘要"
  echo ""

  echo "$json" | jq -r '.sessions[] |
    "### \(.topic)\n- 專案：\(.project)\n- 耗時：\(.time_range.duration_min) 分鐘 / \(.stats.rounds) 回合\n"'
}

# ── ccs-review — session review report ──
ccs-review() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-review [session_id] [options]  — generate session review report

Options:
  --format md|json|html|pdf   Output format (default: md)
  --no-summary            Skip LLM summary cache lookup
  -o DIR                  Write output to directory
  --since DATE            Weekly mode: start date (YYYY-MM-DD)
  --until DATE            Weekly mode: end date (YYYY-MM-DD)
  --summarize             Weekly mode: generate LLM weekly summary

[personal tool, not official Claude Code]
HELP
    return 0
  fi

  local session_id="" format="md" no_summary=false output_dir=""
  local since="" until_date="" summarize=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --format) format="$2"; shift 2 ;;
      --no-summary) no_summary=true; shift ;;
      -o) output_dir="$2"; shift 2 ;;
      --since) since="$2"; shift 2 ;;
      --until) until_date="$2"; shift 2 ;;
      --summarize) summarize=true; shift ;;
      -*) echo "Unknown option: $1" >&2; return 1 ;;
      *) session_id="$1"; shift ;;
    esac
  done

  # Weekly mode
  if [ -n "$since" ]; then
    _ccs_review_weekly "$since" "$until_date" "$format" "$output_dir" "$summarize"
    return $?
  fi

  # Single session mode
  # Resolve jsonl, respecting CCS_PROJECTS_DIR override
  local jsonl
  if [ -n "${CCS_PROJECTS_DIR:-}" ]; then
    if [ -n "$session_id" ]; then
      jsonl=$(find "$CCS_PROJECTS_DIR" -maxdepth 2 -name "${session_id}*.jsonl" ! -path "*/subagents/*" 2>/dev/null | head -1)
    else
      jsonl=$(find "$CCS_PROJECTS_DIR" -maxdepth 2 -name "*.jsonl" ! -path "*/subagents/*" -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -f2)
    fi
  else
    jsonl=$(_ccs_resolve_jsonl "$session_id" "true")
  fi

  if [ -z "$jsonl" ] || [ ! -f "$jsonl" ]; then
    echo "Error: session not found: ${session_id:-<latest>}" >&2
    return 1
  fi

  local review_json
  review_json=$(_ccs_review_json "$jsonl")

  if $no_summary; then
    review_json=$(echo "$review_json" | jq '.summary = null')
  fi

  case "$format" in
    json)
      echo "$review_json"
      ;;
    md)
      echo "$review_json" | _ccs_review_md
      ;;
    html)
      local outfile slug topic_slug date_slug
      topic_slug=$(echo "$review_json" | jq -r '.topic' | tr ' /' '-' | tr -cd '[:alnum:]-' | cut -c1-40)
      date_slug=$(echo "$review_json" | jq -r '.time_range.start' | cut -c1-10)
      slug="${date_slug}-${topic_slug}-review.html"

      if [ -n "$output_dir" ]; then
        mkdir -p "$output_dir"
        outfile="${output_dir}/${slug}"
      else
        outfile="./${slug}"
      fi

      local script_dir="${BASH_SOURCE[0]%/*}"
      echo "$review_json" | python3 "${script_dir}/ccs-review-render.py" > "$outfile"
      echo "HTML written to: $outfile"
      ;;
    pdf)
      local outfile slug topic_slug date_slug
      topic_slug=$(echo "$review_json" | jq -r '.topic' | tr ' /' '-' | tr -cd '[:alnum:]-' | cut -c1-40)
      date_slug=$(echo "$review_json" | jq -r '.time_range.start' | cut -c1-10)
      slug="${date_slug}-${topic_slug}-review.pdf"

      if [ -n "$output_dir" ]; then
        mkdir -p "$output_dir"
        outfile="${output_dir}/${slug}"
      else
        outfile="./${slug}"
      fi

      local script_dir="${BASH_SOURCE[0]%/*}"
      echo "$review_json" | python3 "${script_dir}/ccs-review-render.py" --pdf > "$outfile"
      echo "PDF written to: $outfile"
      ;;
    *)
      echo "Unknown format: $format" >&2
      return 1
      ;;
  esac
}
