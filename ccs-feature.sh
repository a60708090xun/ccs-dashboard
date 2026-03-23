#\!/usr/bin/env bash
# ccs-feature.sh — Feature clustering engine and progress tracking
# Sourced by ccs-dashboard.sh — do not source directly

# ── Feature clustering engine ──


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


# ── ccs-feature — feature progress view ──

# Helper: format "N ago" from minutes

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

