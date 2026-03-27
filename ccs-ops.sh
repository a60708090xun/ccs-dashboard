#\!/usr/bin/env bash
# ccs-ops.sh — Operational commands (ccs-crash, ccs-recap, ccs-checkpoint)
# Sourced by ccs-dashboard.sh — do not source directly

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

  # Count stale crashes (> 3 days)
  local _stale=0 _now_epoch _i
  _now_epoch=$(date +%s)
  for ((_i = 0; _i < ${#_files[@]}; _i++)); do
    local _cf="${_files[$_i]}"
    local _csid
    _csid=$(basename "$_cf" .jsonl)
    [ -n "${_map[$_csid]+x}" ] || continue
    local _age=$(( (_now_epoch - $(stat -c %Y "$_cf")) / 60 ))
    [ "$_age" -ge 4320 ] && (( _stale++ ))
  done

  echo "---"
  if [ "$_stale" -gt 0 ]; then
    echo "> **${_stale}** session(s) older than 3 days — consider \`ccs-crash --clean\` to archive"
    echo ""
  fi
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

# ── ccs-crash: clean by session ID ──
_ccs_crash_clean_by_id() {
  local -n _map=$1 _files=$2
  shift 2
  local -a ids=("$@")

  [ ${#ids[@]} -eq 0 ] && return 0

  local archived=0 not_found=0 ambiguous=0

  for id in "${ids[@]}"; do
    # Find matching session IDs via prefix
    local -a matches=() match_files=()
    local count=${#_files[@]}
    for ((i = 0; i < count; i++)); do
      local f="${_files[$i]}"
      local sid=$(basename "$f" .jsonl)
      [ -n "${_map[$sid]+x}" ] || continue
      if [[ "$sid" == "$id"* ]]; then
        matches+=("$sid")
        match_files+=("$f")
      fi
    done

    if [ ${#matches[@]} -eq 0 ]; then
      printf '  \033[31m✗\033[0m %s — not found\n' "$id"
      not_found=$((not_found + 1))
    elif [ ${#matches[@]} -gt 1 ]; then
      printf '  \033[31m✗\033[0m %s — ambiguous (%d matches):\n' \
        "$id" "${#matches[@]}"
      for ((j = 0; j < ${#matches[@]}; j++)); do
        local topic
        topic=$(_ccs_topic_from_jsonl "${match_files[$j]}")
        printf '      %s — %s\n' \
          "${matches[$j]:0:8}" "$topic"
      done
      ambiguous=$((ambiguous + 1))
    else
      _ccs_archive_session "${match_files[0]}"
      printf '  \033[32m✓\033[0m %s\n' \
        "${matches[0]:0:8}"
      archived=$((archived + 1))
    fi
  done

  local -a parts=()
  [ "$archived" -gt 0 ] && parts+=("$archived archived")
  [ "$not_found" -gt 0 ] && parts+=("$not_found not found")
  [ "$ambiguous" -gt 0 ] && parts+=("$ambiguous ambiguous")
  local IFS=', '
  printf '\n\033[1mDone:\033[0m %s\n' "${parts[*]}"
  [ "$not_found" -eq 0 ] && [ "$ambiguous" -eq 0 ]
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
      --clean)
        mode="clean"; shift
        # Collect session IDs after --clean
        local -a clean_ids=()
        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
          clean_ids+=("$1"); shift
        done
        [ ${#clean_ids[@]} -gt 0 ] && mode="clean-id"
        ;;
      --clean-all)     mode="clean-all"; shift ;;
      --help|-h)
        cat <<'HELP'
ccs-crash  — detect sessions interrupted by crash or unexpected reboot
[personal tool, not official Claude Code]

Usage:
  ccs-crash                    Markdown output (default)
  ccs-crash --json             JSON output
  ccs-crash --all              Include low confidence
  ccs-crash --clean            Interactive cleanup
  ccs-crash --clean <id...>    Archive specific session(s) by ID (prefix match)
  ccs-crash --clean-all        Archive all crashed sessions
  ccs-crash --reboot-window N  Path 1 window (default: 30)
  ccs-crash --idle-window N    Path 2 window (default: 1440)

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
  if ! $show_all && [ "$mode" != "clean-id" ]; then
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
    clean-id)
      _ccs_crash_clean_by_id \
        crash_map session_files "${clean_ids[@]}"
      ;;
  esac
}


# 邏輯: 掃描所有 JSONL mtime，從昨天往回找第一個有活動的日期
_ccs_detect_last_workday() {
  local claude_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"
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
  local claude_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"
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
    local proj_name
    proj_name=$(_ccs_friendly_project_name "$proj_dir")
    local session_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}/$proj_dir"

    # 收集此專案在時間範圍內的 sessions
    local sessions_json="[]"
    local mtime sid topic last_iso age_min status td_done td_pending td_ip preview
    local -a pending_items=()
    while IFS= read -r jsonl; do
      mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || continue
      (( mtime < from_epoch )) && continue

      # Skip short sessions (< 2 user prompts) to reduce noise
      local _pc
      _pc=$(jq -c 'select(.type == "user" and ((.isMeta // false) == false))' "$jsonl" 2>/dev/null | wc -l)
      [ "${_pc:-0}" -lt 2 ] && continue

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

  # Suggested Next Steps (dispatch integration)
  local pending_projects
  pending_projects=$(echo "$json" | jq -r '
    [.projects[] |
      select(
        [.sessions[].pending_items[]?] | length > 0
      ) |
      {
        name: .name,
        count: ([.sessions[].pending_items[]?] | length)
      }
    ] |
    if length > 0 then
      .[] |
      "- **\(.name):** \(.count) pending TODOs"
    else empty end
  ')
  if [ -n "$pending_projects" ]; then
    echo "## Suggested Next Steps"
    echo ""
    echo "$pending_projects"
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
    local proj_name
    proj_name=$(_ccs_friendly_project_name "$proj_dir")
    local session_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}/$proj_dir"

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

      # Skip dispatched task sessions (results reflected in parent)
      [[ "$topic" == Task:* ]] && continue

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

      # Check blocked: two-stage for inactive sessions
      local is_blocked=false
      if (( age_min > 120 )); then
        # Naturally ended? (last message is assistant + no pending todos)
        local last_type
        last_type=$(jq -s '[.[] | select(.type == "assistant" or .type == "user")] | last | .type // ""' "$jsonl" 2>/dev/null)
        if [ "$last_type" = '"assistant"' ] && (( todo_count == 0 )); then
          # Treat as done
          done_json=$(echo "$done_json" | jq -c --arg p "$proj_name" --arg t "$topic" --arg s "$sid" \
            '. + [{project: $p, topic: $t, session: $s}]')
          continue
        else
          is_blocked=true
        fi
      else
        if jq -r 'select(.type == "user" and (.message.content | type == "string") and ((.isMeta // false) == false)) | .message.content' "$jsonl" 2>/dev/null \
          | tail -5 \
          | grep -qiE '(blocked|卡住|等待|waiting|stuck)'; then
          is_blocked=true
        fi
      fi

      # Format last_active time
      local last_active today_ymd mtime_ymd
      today_ymd=$(date +%Y%m%d)
      mtime_ymd=$(date -d "@$mtime" +%Y%m%d)
      if [ "$mtime_ymd" = "$today_ymd" ]; then
        last_active=$(date -d "@$mtime" '+%H:%M')
      else
        last_active=$(date -d "@$mtime" '+%m/%d %H:%M')
      fi

      local entry
      entry=$(jq -nc --arg p "$proj_name" --arg t "$topic" --arg s "$sid" \
        --arg la "$last_active" \
        --argjson todos "$todos_json" --argjson tc "$todo_count" \
        '{project: $p, topic: $t, session: $s, last_active: $la, todos: $todos, todo_count: $tc}')

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

  # Done — collapsed
  local d_count
  d_count=$(echo "$json" | jq '.done | length')
  printf '\033[1;32m✅ Done (%d)\033[0m\n' "$d_count"
  if (( d_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '
      [.done[] | {project}] | group_by(.project) |
      map("  " + .[0].project + " — " + (length|tostring) + " session" + (if length > 1 then "s" else "" end)) |
      .[]'
  fi

  echo
  # In Progress — grouped with time
  local w_count
  w_count=$(echo "$json" | jq '.in_progress | length')
  printf '\033[1;33m🔄 In Progress\033[0m\n'
  if (( w_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '
      .in_progress | group_by(.project) | .[] |
      if length >= 2 then
        "  " + .[0].project + " (" + (length|tostring) + ")",
        (.[] | "    " + .topic + "  " + .last_active,
          (.todos[]? | "      [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content))
      else
        .[] | "  " + .project + "  " + .topic + "  " + .last_active,
          (.todos[]? | "    [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content)
      end' 2>/dev/null
  fi

  echo
  # Blocked — grouped with time
  local b_count
  b_count=$(echo "$json" | jq '.blocked | length')
  printf '\033[1;31m⚠️  Blocked\033[0m\n'
  if (( b_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '
      .blocked | group_by(.project) | .[] |
      if length >= 2 then
        "  " + .[0].project + " (" + (length|tostring) + ")",
        (.[] | "    " + .topic + "  " + .last_active,
          (.todos[]? | "      [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content))
      else
        .[] | "  " + .project + "  " + .topic + "  " + .last_active,
          (.todos[]? | "    [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content)
      end' 2>/dev/null
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

  # Done — collapsed summary
  local d_count
  d_count=$(echo "$json" | jq '.done | length')
  printf '### Done (%d)\n' "$d_count"
  if (( d_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '
      [.done[] | {project}] | group_by(.project) |
      map("- **" + .[0].project + "** — " + (length|tostring) + " session" + (if length > 1 then "s" else "" end)) |
      .[]'
  fi

  # In Progress — grouped by project with time
  printf '\n### In Progress\n'
  local w_count
  w_count=$(echo "$json" | jq '.in_progress | length')
  if (( w_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '
      .in_progress | group_by(.project) | .[] |
      if length >= 2 then
        "**" + .[0].project + "** (" + (length|tostring) + ")",
        (.[] | "- " + .topic + " _(" + .last_active + ")_",
          (.todos[]? | "  - [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content))
      else
        .[] | "- **" + .project + "** — " + .topic + " _(" + .last_active + ")_",
          (.todos[]? | "  - [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content)
      end' 2>/dev/null
  fi

  # Blocked — grouped by project with time
  printf '\n### Blocked\n'
  local b_count
  b_count=$(echo "$json" | jq '.blocked | length')
  if (( b_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '
      .blocked | group_by(.project) | .[] |
      if length >= 2 then
        "**" + .[0].project + "** (" + (length|tostring) + ")",
        (.[] | "- " + .topic + " _(" + .last_active + ")_",
          (.todos[]? | "  - [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content))
      else
        .[] | "- **" + .project + "** — " + .topic + " _(" + .last_active + ")_",
          (.todos[]? | "  - [" + (if .status == "in_progress" then "~" else " " end) + "] " + .content)
      end' 2>/dev/null
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
  printf '| %s | %s | %s | %s |\n' "狀態" "專案" "項目" "時間"
  printf '|------|------|------|------|\n'

  # Done — collapsed per project
  echo "$json" | jq -r '
    [.done[] | {project}] | group_by(.project) |
    map("| Done | " + .[0].project + " | " + (length|tostring) + " sessions | — |") |
    .[]' 2>/dev/null

  # In Progress + Blocked — with time
  echo "$json" | jq -r '
    (.in_progress[] | "| WIP | \(.project) | \(.topic)\(if .todo_count > 0 then " (\(.todo_count) todos)" else "" end) | \(.last_active) |"),
    (.blocked[] | "| Blocked | \(.project) | \(.topic)\(if .todo_count > 0 then " (\(.todo_count) todos)" else "" end) | \(.last_active) |")
  ' 2>/dev/null

  local total
  total=$(echo "$json" | jq '.summary.total')
  (( total == 0 )) && printf '| - | - | (none) | - |\n'
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
