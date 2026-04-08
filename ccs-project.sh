#!/usr/bin/env bash
# ccs-project.sh — Per-project insight report
# Part of ccs-dashboard. Sourced by ccs-dashboard.sh automatically.
#
# Functions:
#   _ccs_project_collect     — collect session JSONLs for a project
#   _ccs_project_path_to_dir — resolve filesystem path -> encoded dir name
#   _ccs_project_json        — build project report JSON
#   _ccs_project_md          — render project JSON as markdown
#   ccs-project              — CLI entry point
#
# Depends on ccs-core.sh:
#   _ccs_find_project_dir, _ccs_resolve_project_path,
#   _ccs_session_stats, _ccs_topic_from_jsonl, _ccs_data_dir
# Depends on ccs-feature.sh:
#   features.jsonl (read only)

# ── Constants ──
_CCS_PROJECT_MAX_SESSIONS=50
_CCS_PROJECT_MAX_DAYS=90

# ── Helper: collect session JSONLs for a project ──
# Args: encoded_dir_name [since_date] [until_date]
# Output: one JSONL path per line, sorted by mtime descending, auto-truncated
_ccs_project_collect() {
  local encoded_dir="$1"
  local since="${2:-}"
  local until_date="${3:-}"
  local projects_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"
  local target_dir="$projects_dir/$encoded_dir"

  [ -d "$target_dir" ] || return 1

  # Collect all JSONLs, sorted by mtime descending
  local -a all_files=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    all_files+=("${line#*$'\t'}")
  done < <(find "$target_dir" -maxdepth 1 -name "*.jsonl" \
    ! -path "*/subagents/*" -printf '%T@\t%p\n' 2>/dev/null \
    | sort -rn)

  [ ${#all_files[@]} -eq 0 ] && return 0

  # Apply date filters
  local since_epoch=0 until_epoch=999999999999
  if [ -n "$since" ]; then
    since_epoch=$(date -d "$since" +%s 2>/dev/null || echo 0)
  fi
  if [ -n "$until_date" ]; then
    until_epoch=$(date -d "$until_date 23:59:59" +%s 2>/dev/null || echo 999999999999)
  fi

  # Auto-truncation: max days (from now)
  local max_days_epoch
  max_days_epoch=$(date -d "$_CCS_PROJECT_MAX_DAYS days ago" +%s 2>/dev/null)

  # Use the stricter of since_epoch and max_days_epoch
  if [ "$max_days_epoch" -gt "$since_epoch" ] && [ -z "$since" ]; then
    since_epoch=$max_days_epoch
  fi

  local -a filtered=()
  local f mtime
  for f in "${all_files[@]}"; do
    mtime=$(stat -c "%Y" "$f" 2>/dev/null || echo 0)
    if [ "$mtime" -ge "$since_epoch" ] && [ "$mtime" -le "$until_epoch" ]; then
      filtered+=("$f")
    fi
    # Auto-truncation: max sessions
    [ ${#filtered[@]} -ge $_CCS_PROJECT_MAX_SESSIONS ] && break
  done

  printf '%s\n' "${filtered[@]}"
}

# ── Helper: aggregate cost stats from file list on stdin ──
# Input: one JSONL path per line on stdin
# Output: JSON with session_count, total_rounds, total_duration_min, estimated_hours, avg_turns_per_session
_ccs_project_cost_from_files() {
  local total_rounds=0 total_duration=0 total_chars=0 total_tokens=0
  local session_count=0
  local -a active_dates=()

  while IFS= read -r jsonl_file; do
    [ -z "$jsonl_file" ] && continue
    session_count=$((session_count + 1))

    local stats
    stats=$(_ccs_session_stats "$jsonl_file")

    total_rounds=$(( total_rounds + $(echo "$stats" | jq '.rounds') ))
    total_duration=$(( total_duration + $(echo "$stats" | jq '.time_range.duration_min') ))
    total_chars=$(( total_chars + $(echo "$stats" | jq '.char_count') ))
    total_tokens=$(( total_tokens + $(echo "$stats" | jq '.token_estimate') ))

    local session_date
    session_date=$(echo "$stats" | jq -r '.time_range.start' | cut -c1-10)
    [ -n "$session_date" ] && [ "$session_date" != "null" ] && active_dates+=("$session_date")
  done

  local estimated_hours
  estimated_hours=$(awk "BEGIN {printf \"%.1f\", $total_duration / 60}")

  local avg_turns=0
  [ "$session_count" -gt 0 ] && avg_turns=$(awk "BEGIN {printf \"%.1f\", $total_rounds / $session_count}")

  local unique_days=0
  [ ${#active_dates[@]} -gt 0 ] && unique_days=$(printf '%s\n' "${active_dates[@]}" | sort -u | wc -l)

  jq -n \
    --argjson session_count "$session_count" \
    --argjson total_rounds "$total_rounds" \
    --argjson total_duration "$total_duration" \
    --arg estimated_hours "$estimated_hours" \
    --arg avg_turns "$avg_turns" \
    --argjson total_chars "$total_chars" \
    --argjson total_tokens "$total_tokens" \
    --argjson active_days "$unique_days" \
    '{
      session_count: $session_count,
      total_rounds: $total_rounds,
      total_duration_min: $total_duration,
      estimated_hours: ($estimated_hours | tonumber),
      avg_turns_per_session: ($avg_turns | tonumber),
      total_char_count: $total_chars,
      total_token_estimate: $total_tokens,
      active_days: $active_days
    }'
}

# ── Helper: aggregate cost stats for a project (convenience wrapper) ──
# Args: encoded_dir_name [since] [until]
_ccs_project_cost() {
  local encoded_dir="$1" since="${2:-}" until_date="${3:-}"
  _ccs_project_collect "$encoded_dir" "$since" "$until_date" | _ccs_project_cost_from_files
}

# ── Helper: analyze development rhythm from file list on stdin ──
# Input: one JSONL path per line on stdin
# Output: JSON with heatmap, longest_streak, longest_gap, avg_sessions_per_day
_ccs_project_rhythm_from_files() {
  local -A date_counts=()
  while IFS= read -r jsonl_file; do
    [ -z "$jsonl_file" ] && continue
    local session_date
    session_date=$(jq -r 'select(.timestamp) | .timestamp' "$jsonl_file" 2>/dev/null \
      | head -1 | cut -c1-10)
    [ -z "$session_date" ] || [ "$session_date" = "null" ] && continue
    date_counts[$session_date]=$(( ${date_counts[$session_date]:-0} + 1 ))
  done

  [ ${#date_counts[@]} -eq 0 ] && {
    echo '{"heatmap":[],"longest_streak":0,"longest_gap":0,"avg_sessions_per_day":0}'
    return 0
  }

  local -a sorted_dates=()
  local heatmap_json="["
  local first=true
  while IFS= read -r d; do
    sorted_dates+=("$d")
    $first || heatmap_json+=","
    first=false
    heatmap_json+="{\"date\":\"$d\",\"sessions\":${date_counts[$d]}}"
  done < <(printf '%s\n' "${!date_counts[@]}" | sort)
  heatmap_json+="]"

  local longest_streak=1 current_streak=1
  local longest_gap=0
  local i prev_epoch curr_epoch diff_days
  for ((i = 1; i < ${#sorted_dates[@]}; i++)); do
    prev_epoch=$(date -d "${sorted_dates[$((i-1))]}" +%s 2>/dev/null)
    curr_epoch=$(date -d "${sorted_dates[$i]}" +%s 2>/dev/null)
    diff_days=$(( (curr_epoch - prev_epoch) / 86400 ))

    if [ "$diff_days" -eq 1 ]; then
      current_streak=$((current_streak + 1))
      [ "$current_streak" -gt "$longest_streak" ] && longest_streak=$current_streak
    else
      current_streak=1
      local gap=$((diff_days - 1))
      [ "$gap" -gt "$longest_gap" ] && longest_gap=$gap
    fi
  done

  local total_sessions=0
  for d in "${!date_counts[@]}"; do
    total_sessions=$((total_sessions + date_counts[$d]))
  done
  local avg_per_day
  avg_per_day=$(awk "BEGIN {printf \"%.1f\", $total_sessions / ${#sorted_dates[@]}}")

  jq -n \
    --argjson heatmap "$heatmap_json" \
    --argjson longest_streak "$longest_streak" \
    --argjson longest_gap "$longest_gap" \
    --arg avg "$avg_per_day" \
    '{
      heatmap: $heatmap,
      longest_streak: $longest_streak,
      longest_gap: $longest_gap,
      avg_sessions_per_day: ($avg | tonumber)
    }'
}

# ── Helper: analyze development rhythm (convenience wrapper) ──
# Args: encoded_dir_name [since] [until]
_ccs_project_rhythm() {
  local encoded_dir="$1" since="${2:-}" until_date="${3:-}"
  _ccs_project_collect "$encoded_dir" "$since" "$until_date" | _ccs_project_rhythm_from_files
}

# ── Helper: filter features.jsonl for a specific project ──
# Args: project_path (resolved filesystem path)
# Output: JSON array of feature objects for this project
_ccs_project_features() {
  local project_path="$1"
  local data_dir="${CCS_DATA_DIR:-$(_ccs_data_dir)}"
  local features_file="$data_dir/features.jsonl"

  if [ ! -f "$features_file" ]; then
    echo "[]"
    return 0
  fi

  jq -sc --arg proj "$project_path" '
    [.[] | select(.project == $proj and .id != "_ungrouped")]
  ' "$features_file" 2>/dev/null || echo "[]"
}

# ── Helper: analyze code changes from git ──
# Args: project_path max_days
# Output: JSON with by_branch, top_files, lines_added, lines_deleted
_ccs_project_code_changes() {
  local project_path="$1" max_days="${2:-90}"

  if [ ! -d "$project_path/.git" ]; then
    echo '{"by_branch":[],"top_files":[],"lines_added":0,"lines_deleted":0}'
    return 0
  fi

  local since_date
  since_date=$(date -d "$max_days days ago" +%Y-%m-%d 2>/dev/null)

  # Per-branch analysis (variable-based, no temp files)
  local by_branch="[]"

  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    branch="${branch#  }"
    branch="${branch#\* }"

    local commit_count
    commit_count=$(git -C "$project_path" log "$branch" --since="$since_date" \
      --oneline 2>/dev/null | wc -l)
    [ "$commit_count" -eq 0 ] && continue

    local summary
    summary=$(git -C "$project_path" log "$branch" --since="$since_date" \
      --oneline 2>/dev/null | head -3 | paste -sd '; ')

    local entry
    entry=$(jq -n \
      --arg branch "$branch" \
      --argjson commits "$commit_count" \
      --arg summary "$summary" \
      '{branch: $branch, commits: $commits, summary: $summary}')
    by_branch=$(echo "$by_branch" | jq --argjson entry "$entry" '. + [$entry]')
  done < <(git -C "$project_path" branch 2>/dev/null)

  # Top modified files
  local top_files
  top_files=$(git -C "$project_path" log --all --since="$since_date" \
    --pretty=format: --name-only 2>/dev/null \
    | grep -v '^$' | sort | uniq -c | sort -rn | head -10 \
    | awk '{print "{\"path\":\""$2"\",\"changes\":"$1"}"}' \
    | jq -s '.' 2>/dev/null || echo "[]")

  # Total lines added/deleted
  local diffstat
  diffstat=$(git -C "$project_path" log --all --since="$since_date" \
    --pretty=format: --numstat 2>/dev/null \
    | awk '{a+=$1; d+=$2} END {print a+0, d+0}')
  local lines_added lines_deleted
  lines_added=$(echo "$diffstat" | cut -d' ' -f1)
  lines_deleted=$(echo "$diffstat" | cut -d' ' -f2)

  jq -n \
    --argjson by_branch "$by_branch" \
    --argjson top_files "$top_files" \
    --argjson lines_added "$lines_added" \
    --argjson lines_deleted "$lines_deleted" \
    '{
      by_branch: $by_branch,
      top_files: $top_files,
      lines_added: $lines_added,
      lines_deleted: $lines_deleted
    }'
}

# ── Helper: build complete project report JSON ──
# Args: encoded_dir_name [since] [until]
_ccs_project_json() {
  local encoded_dir="$1" since="${2:-}" until_date="${3:-}"

  local project_path
  project_path=$(_ccs_resolve_project_path "$encoded_dir" 2>/dev/null || echo "")
  local project_name
  project_name=$(basename "$project_path" 2>/dev/null || echo "$encoded_dir")

  # Collect sessions
  local -a session_files=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    session_files+=("$f")
  done < <(_ccs_project_collect "$encoded_dir" "$since" "$until_date")

  local session_count=${#session_files[@]}

  # Total count for truncation indicator
  local projects_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"
  local total_count
  total_count=$(find "$projects_dir/$encoded_dir" -maxdepth 1 -name "*.jsonl" \
    ! -path "*/subagents/*" 2>/dev/null | wc -l)

  local truncated=false truncated_total=null
  if [ "$total_count" -gt "$session_count" ]; then
    truncated=true
    truncated_total=$total_count
  fi

  # Period from/to dates
  local period_from="" period_to=""
  if [ "$session_count" -gt 0 ]; then
    period_from=$(jq -r 'select(.timestamp) | .timestamp' "${session_files[-1]}" 2>/dev/null \
      | head -1 | cut -c1-10)
    period_to=$(jq -r 'select(.timestamp) | .timestamp' "${session_files[0]}" 2>/dev/null \
      | head -1 | cut -c1-10)
  fi

  local total_days=0
  if [ -n "$period_from" ] && [ -n "$period_to" ] \
     && [ "$period_from" != "null" ] && [ "$period_to" != "null" ]; then
    local from_epoch to_epoch
    from_epoch=$(date -d "$period_from" +%s 2>/dev/null || echo 0)
    to_epoch=$(date -d "$period_to" +%s 2>/dev/null || echo 0)
    total_days=$(( (to_epoch - from_epoch) / 86400 + 1 ))
  fi

  # Single-pass: compute cost + session list + rhythm dates simultaneously
  # (avoids triple collection and double parsing of _ccs_session_stats)
  local total_rounds=0 total_duration=0 total_chars=0 total_tokens=0
  local -a active_dates=()
  local -a sess_jsons=()

  if [ "$session_count" -gt 0 ]; then
    local f
    for f in "${session_files[@]}"; do
      local sid topic sstats turns duration_min session_date
      sid=$(basename "$f" .jsonl | cut -c1-8)
      topic=$(_ccs_topic_from_jsonl "$f")
      sstats=$(_ccs_session_stats "$f")
      turns=$(echo "$sstats" | jq '.rounds')
      duration_min=$(echo "$sstats" | jq '.time_range.duration_min')
      session_date=$(echo "$sstats" | jq -r '.time_range.start' | cut -c1-10)

      # Accumulate cost stats
      total_rounds=$(( total_rounds + turns ))
      total_duration=$(( total_duration + duration_min ))
      total_chars=$(( total_chars + $(echo "$sstats" | jq '.char_count') ))
      total_tokens=$(( total_tokens + $(echo "$sstats" | jq '.token_estimate') ))
      [ -n "$session_date" ] && [ "$session_date" != "null" ] && active_dates+=("$session_date")

      # Build session list entry
      sess_jsons+=("$(jq -n \
        --arg sid "$sid" \
        --arg date "$session_date" \
        --arg topic "$topic" \
        --argjson turns "$turns" \
        --argjson duration_min "$duration_min" \
        '{sid: $sid, date: $date, topic: $topic, turns: $turns, duration_min: $duration_min}')")
    done
  fi

  local sessions_array="[]"
  [ ${#sess_jsons[@]} -gt 0 ] && sessions_array=$(printf '%s\n' "${sess_jsons[@]}" | jq -s '.')

  # Build cost JSON from accumulated stats
  local estimated_hours avg_turns unique_days
  estimated_hours=$(awk "BEGIN {printf \"%.1f\", $total_duration / 60}")
  avg_turns=0
  [ "$session_count" -gt 0 ] && avg_turns=$(awk "BEGIN {printf \"%.1f\", $total_rounds / $session_count}")
  unique_days=0
  [ ${#active_dates[@]} -gt 0 ] && unique_days=$(printf '%s\n' "${active_dates[@]}" | sort -u | wc -l)

  local cost_json
  cost_json=$(jq -n \
    --argjson session_count "$session_count" \
    --argjson total_rounds "$total_rounds" \
    --argjson total_duration "$total_duration" \
    --arg estimated_hours "$estimated_hours" \
    --arg avg_turns "$avg_turns" \
    --argjson total_chars "$total_chars" \
    --argjson total_tokens "$total_tokens" \
    --argjson active_days "$unique_days" \
    '{
      session_count: $session_count,
      total_rounds: $total_rounds,
      total_duration_min: $total_duration,
      estimated_hours: ($estimated_hours | tonumber),
      avg_turns_per_session: ($avg_turns | tonumber),
      total_char_count: $total_chars,
      total_token_estimate: $total_tokens,
      active_days: $active_days
    }')
  local active_days_count="$unique_days"

  # Rhythm: compute from collected dates (no re-collection)
  local rhythm_json
  rhythm_json=$(printf '%s\n' "${session_files[@]}" | _ccs_project_rhythm_from_files)

  # Features
  local features_json
  features_json=$(_ccs_project_features "$project_path")

  # Code changes
  local max_days=$_CCS_PROJECT_MAX_DAYS
  if [ -n "$since" ]; then
    local since_epoch now_epoch
    since_epoch=$(date -d "$since" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    max_days=$(( (now_epoch - since_epoch) / 86400 + 1 ))
  fi
  local code_json
  code_json=$(_ccs_project_code_changes "$project_path" "$max_days")

  # Insights cache
  local insights="null"
  local data_dir
  data_dir="${CCS_DATA_DIR:-$(_ccs_data_dir)}"
  local cache_file="$data_dir/project-cache/${encoded_dir}.insights.json"
  if [ -f "$cache_file" ]; then
    local cache_age
    cache_age=$(( ($(date +%s) - $(stat -c "%Y" "$cache_file")) / 3600 ))
    if [ "$cache_age" -lt 24 ]; then
      insights=$(cat "$cache_file")
    fi
  fi

  # Assemble
  jq -n \
    --arg project "$project_path" \
    --arg project_name "$project_name" \
    --arg period_from "$period_from" \
    --arg period_to "$period_to" \
    --argjson total_days "$total_days" \
    --argjson active_days "$active_days_count" \
    --argjson session_count "$session_count" \
    --argjson truncated "$truncated" \
    --argjson truncated_total "$truncated_total" \
    --argjson cost "$cost_json" \
    --argjson features "$features_json" \
    --argjson rhythm "$rhythm_json" \
    --argjson code_changes "$code_json" \
    --argjson insights "$insights" \
    --argjson sessions "$sessions_array" \
    '{
      project: $project,
      project_name: $project_name,
      period: {
        from: $period_from,
        to: $period_to,
        total_days: $total_days,
        active_days: $active_days,
        session_count: $session_count,
        truncated: $truncated,
        truncated_total: $truncated_total
      },
      cost: $cost,
      features: $features,
      rhythm: $rhythm,
      code_changes: $code_changes,
      insights: $insights,
      sessions: $sessions
    }'
}

# ── Helper: render project JSON as markdown ──
# Reads JSON from stdin
_ccs_project_md() {
  local json
  json=$(cat)

  local project_name period_from period_to total_days active_days session_count
  project_name=$(echo "$json" | jq -r '.project_name')
  period_from=$(echo "$json" | jq -r '.period.from')
  period_to=$(echo "$json" | jq -r '.period.to')
  total_days=$(echo "$json" | jq '.period.total_days')
  active_days=$(echo "$json" | jq '.period.active_days')
  session_count=$(echo "$json" | jq '.period.session_count')

  local truncated truncated_msg=""
  truncated=$(echo "$json" | jq '.period.truncated')
  if [ "$truncated" = "true" ]; then
    local truncated_total
    truncated_total=$(echo "$json" | jq '.period.truncated_total')
    truncated_msg=" _(顯示最近 ${session_count} 個，共 ${truncated_total} 個)_"
  fi

  local est_hours avg_turns total_rounds
  est_hours=$(echo "$json" | jq '.cost.estimated_hours')
  avg_turns=$(echo "$json" | jq '.cost.avg_turns_per_session')
  total_rounds=$(echo "$json" | jq '.cost.total_rounds')

  echo "# Project Report: ${project_name}"
  echo ""
  echo "**期間：** ${period_from} ~ ${period_to}（${total_days} 天）"
  echo "**Session 數：** ${session_count}${truncated_msg} | **活躍天：** ${active_days} | **估算工時：** ${est_hours}h"
  echo ""

  # Features
  local feat_count
  feat_count=$(echo "$json" | jq '.features | length')
  if [ "$feat_count" -gt 0 ]; then
    echo "## 功能進度"
    echo ""
    echo "$json" | jq -r '.features[] |
      (if .status == "completed" then "✅"
       elif .status == "in_progress" then "🔵"
       elif .status == "stale" then "🟡"
       else "⚪" end) as $icon |
      "\($icon) \(.branch // .id) — \(.label) (\(.todos_done)/\(.todos_total) todos)"'
    echo ""
  fi

  # Cost
  echo "## 投入成本"
  echo ""
  echo "- 總 turns: ${total_rounds}（平均 ${avg_turns}/session）"
  echo "- 估算工時: ${est_hours}h（${session_count} sessions）"
  echo ""

  # Rhythm
  local longest_streak longest_gap avg_per_day
  longest_streak=$(echo "$json" | jq '.rhythm.longest_streak')
  longest_gap=$(echo "$json" | jq '.rhythm.longest_gap')
  avg_per_day=$(echo "$json" | jq '.rhythm.avg_sessions_per_day')

  echo "## 開發節奏"
  echo ""
  echo "- 最長連續: ${longest_streak} 天 | 最長中斷: ${longest_gap} 天"
  echo "- 平均: ${avg_per_day} sessions/天"
  echo ""

  # Code changes
  local lines_added lines_deleted
  lines_added=$(echo "$json" | jq '.code_changes.lines_added')
  lines_deleted=$(echo "$json" | jq '.code_changes.lines_deleted')

  echo "## 程式碼變動"
  echo ""
  echo "- +${lines_added} / -${lines_deleted} 行"
  echo ""

  local branch_count
  branch_count=$(echo "$json" | jq '.code_changes.by_branch | length')
  if [ "$branch_count" -gt 0 ]; then
    echo "$json" | jq -r '.code_changes.by_branch[] |
      "- \(.branch) (\(.commits) commits): \(.summary)"'
    echo ""
  fi

  local top_count
  top_count=$(echo "$json" | jq '.code_changes.top_files | length')
  if [ "$top_count" -gt 0 ]; then
    echo "**修改最多的檔案：**"
    echo "$json" | jq -r '.code_changes.top_files[:10][] | "- \(.path) (\(.changes)x)"'
    echo ""
  fi

  # Insights
  local has_insights
  has_insights=$(echo "$json" | jq '.insights != null')
  if [ "$has_insights" = "true" ]; then
    echo "## 洞察"
    echo ""
    echo "$json" | jq -r '.insights.health_summary // empty'
    echo ""
    local issues_count
    issues_count=$(echo "$json" | jq '.insights.recurring_issues | length // 0')
    if [ "$issues_count" -gt 0 ]; then
      echo "**重複問題：**"
      echo "$json" | jq -r '.insights.recurring_issues[]? | "- \(.)"'
      echo ""
    fi
    local suggestions_count
    suggestions_count=$(echo "$json" | jq '.insights.suggestions | length // 0')
    if [ "$suggestions_count" -gt 0 ]; then
      echo "**建議：**"
      echo "$json" | jq -r '.insights.suggestions[]? | "- \(.)"'
      echo ""
    fi
  fi

  # Session list
  echo "## Session 列表"
  echo ""
  echo "$json" | jq -r '.sessions[] |
    "- [\(.sid)] \(.date) — \(.topic) (\(.turns) turns, \(.duration_min)min)"'
}

# ── CLI entry point ──
ccs-project() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-project — per-project insight report
[personal tool, not official Claude Code]

Usage:
  ccs-project                         Report for current directory's project
  ccs-project /path/to/repo           Report for specified project
  ccs-project --since 2026-03-01      Limit time range
  ccs-project --format html -o ./     Output as HTML

Options:
  --project PATH        Explicit project path (alternative to positional arg)
  --since DATE          Start date (YYYY-MM-DD)
  --until DATE          End date (YYYY-MM-DD, default: today)
  --format md|html|json Output format (default: md)
  -o, --output DIR      Output directory for html
  --no-insights         Skip LLM insights cache lookup

Auto-truncation: max 50 sessions or 90 days (whichever is stricter).
HELP
    return 0
  fi

  local project_path="" format="md" output_dir="" since="" until_date=""
  local no_insights=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project_path="$2"; shift 2 ;;
      --since) since="$2"; shift 2 ;;
      --until) until_date="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      -o|--output) output_dir="$2"; shift 2 ;;
      --no-insights) no_insights=true; shift ;;
      -*) echo "ccs-project: unknown option: $1" >&2; return 1 ;;
      *) project_path="$1"; shift ;;
    esac
  done

  # Resolve project path → encoded dir name
  if [ -z "$project_path" ]; then
    project_path=$(pwd)
  fi
  project_path=$(realpath "$project_path" 2>/dev/null || echo "$project_path")

  local encoded_dir
  encoded_dir=$(_ccs_find_project_dir "$project_path")
  if [ -z "$encoded_dir" ]; then
    echo "ccs-project: no sessions found for $project_path" >&2
    return 1
  fi

  # Build JSON
  local project_json
  project_json=$(_ccs_project_json "$encoded_dir" "$since" "$until_date")

  if $no_insights; then
    project_json=$(echo "$project_json" | jq '.insights = null')
  fi

  case "$format" in
    json)
      echo "$project_json"
      ;;
    md)
      echo "$project_json" | _ccs_project_md
      ;;
    html)
      local script_dir="${BASH_SOURCE[0]%/*}"
      local html
      html=$(echo "$project_json" | python3 "$script_dir/ccs-project-render.py")
      if [ -n "$output_dir" ]; then
        local project_name
        project_name=$(echo "$project_json" | jq -r '.project_name')
        local outfile="${output_dir}/${project_name}-project-report.html"
        echo "$html" > "$outfile"
        echo "ccs-project: written to $outfile"
      else
        echo "$html"
      fi
      ;;
    *)
      echo "ccs-project: unknown format: $format" >&2
      return 1
      ;;
  esac
}
