# Daily Recap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ccs-recap` command for daily work progress review, with bash data layer + skill AI analysis layer.

**Architecture:** Dual-layer — bash layer (`ccs-recap`) collects 7 dimensions of data from JSONL sessions, git repos, and features.jsonl, outputting terminal/markdown/JSON. Skill layer (ccs-orchestrator extension) consumes JSON output for AI-powered context analysis and priority suggestions.

**Tech Stack:** Bash 4+, jq, coreutils, existing ccs-dashboard helpers

**Spec:** `docs/specs/2026-03-19-daily-recap-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `ccs-dashboard.sh` | Modify (append after line 3140) | All recap functions: helpers + main command |
| `skills/ccs-orchestrator/SKILL.md` | Modify (lines 33-49, 50-70) | Add recap to Command Palette + Routing Rules |
| `install.sh` | Modify (line 151) | Add `ccs-recap` to available commands list |
| `README.md` | Modify | Document `ccs-recap` command |

所有新函數加在 `ccs-dashboard.sh` 末尾（line 3141+），遵循現有 single-file 慣例。

---

## Task 1: `_ccs_detect_last_workday` helper

**Files:**
- Modify: `ccs-dashboard.sh` (append after line 3140)

- [ ] **Step 1: 實作 `_ccs_detect_last_workday`**

```bash
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
```

- [ ] **Step 2: 驗證 helper**

```bash
source ccs-dashboard.sh
# 測試：應回傳一個合理的 epoch（昨天或更早）
ts=$(_ccs_detect_last_workday)
echo "Last workday: $(date -d @"$ts" '+%Y-%m-%d %A')"
# 預期：顯示最近有 session 活動的日期（不含今天）
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add _ccs_detect_last_workday helper for daily recap"
```

---

## Task 2: `_ccs_recap_scan_projects` helper

**Files:**
- Modify: `ccs-dashboard.sh` (append)

- [ ] **Step 1: 實作 `_ccs_recap_scan_projects`**

列出時間範圍內有活動的專案。

```bash
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
```

- [ ] **Step 2: 驗證 helper**

```bash
source ccs-dashboard.sh
from=$(_ccs_detect_last_workday)
echo "=== Projects active since $(date -d @"$from" +%Y-%m-%d) ==="
_ccs_recap_scan_projects "$from"
# 預期：列出有活動的專案目錄名
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add _ccs_recap_scan_projects helper"
```

---

## Task 3: `_ccs_recap_collect` — 核心數據收集

**Files:**
- Modify: `ccs-dashboard.sh` (append)

此為最核心的函數，整合 7 個維度數據。分步實作。

- [ ] **Step 1: 實作框架 + sessions 維度**

```bash
# _ccs_recap_collect — 收集 recap 數據，輸出 JSON
# $1: from_epoch
# $2: "all" 或 "project" (專案範圍)
_ccs_recap_collect() {
  local from_epoch=${1:?missing from_epoch}
  local scope=${2:-all}
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
      if tail -20 "$jsonl" 2>/dev/null | grep -q '"type":"last-prompt"'; then
        status="completed"
      fi

      # Todos
      td_done=0 td_pending=0 td_ip=0
      pending_items=()
      while IFS=$'\t' read -r t_status t_content; do
        case "$t_status" in
          completed)    (( td_done++ )) ;;
          pending)      (( td_pending++ )); pending_items+=("$t_content") ;;
          in_progress)  (( td_ip++ )); pending_items+=("$t_content") ;;
        esac
      done < <(jq -r 'select(.type == "assistant") | .message.content[]? |
        select(.type == "tool_use" and .name == "TodoWrite") |
        .input.todos[]? | [.status, .content] | @tsv' "$jsonl" 2>/dev/null | tail -20)

      # Last exchange preview
      local preview=""
      preview=$(jq -r 'select(.type == "user" and .isMeta != true) |
        .message.content | if type == "string" then . else "" end |
        gsub("\n"; " ") | .[:80]' "$jsonl" 2>/dev/null | tail -1)

      # 組裝 session JSON
      local pending_json
      pending_json=$(printf '%s\n' "${pending_items[@]}" | jq -R . | jq -s .)
      sessions_json=$(echo "$sessions_json" | jq \
        --arg id "$sid" \
        --arg topic "$topic" \
        --arg status "$status" \
        --arg last "$last_iso" \
        --argjson done "$td_done" \
        --argjson pend "$td_pending" \
        --argjson ip "$td_ip" \
        --argjson items "$pending_json" \
        --arg preview "$preview" \
        '. += [{
          id: $id, topic: $topic, status: $status,
          last_active: $last,
          todos: { done: ($done|tonumber), pending: ($pend|tonumber), in_progress: ($ip|tonumber) },
          pending_items: $items,
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
        grep -iE '(deadline|before|週|月底|by |due|urgent|ASAP|趕|今天|明天|後天)' |
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
    --argjson auto true \
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
```

- [ ] **Step 2: 驗證 JSON 輸出**

```bash
source ccs-dashboard.sh
from=$(_ccs_detect_last_workday)
_ccs_recap_collect "$from" "all" | jq .
# 預期：完整的 JSON 結構，包含 recap_period, projects, summary
# 驗證：每個 project 有 sessions, features, git, hot_files, deadlines
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add _ccs_recap_collect core data aggregation"
```

---

## Task 4: `_ccs_recap_terminal` — Terminal 色彩輸出

**Files:**
- Modify: `ccs-dashboard.sh` (append)

- [ ] **Step 1: 實作 terminal renderer**

參考 `_ccs_overview_terminal`（line 2069-2135）和 `_ccs_feature_terminal`（line 2605-2699）的 ANSI 色彩模式。

```bash
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
  echo "$json" | jq -r '.projects[] |
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
```

- [ ] **Step 2: 驗證 terminal 輸出**

```bash
source ccs-dashboard.sh
from=$(_ccs_detect_last_workday)
json=$(_ccs_recap_collect "$from" "all")
_ccs_recap_terminal "$json"
# 預期：有色彩的 terminal 輸出，包含 7 個區塊
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add _ccs_recap_terminal renderer"
```

---

## Task 5: `_ccs_recap_md` — Markdown 輸出

**Files:**
- Modify: `ccs-dashboard.sh` (append)

- [ ] **Step 1: 實作 markdown renderer**

參考 `_ccs_overview_md`（line 1437-1589）格式。

```bash
_ccs_recap_md() {
  local json="$1"
  local from to
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
  echo "$json" | jq -r '.projects[] |
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
```

- [ ] **Step 2: 驗證 markdown 輸出**

```bash
source ccs-dashboard.sh
from=$(_ccs_detect_last_workday)
json=$(_ccs_recap_collect "$from" "all")
_ccs_recap_md "$json"
# 預期：合法的 Markdown，可直接給 skill 層消費
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add _ccs_recap_md markdown renderer"
```

---

## Task 6: `ccs-recap` 主指令

**Files:**
- Modify: `ccs-dashboard.sh` (append)

- [ ] **Step 1: 實作主指令**

```bash
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
  local from_epoch
  if [ -z "$time_arg" ]; then
    from_epoch=$(_ccs_detect_last_workday)
  elif [[ "$time_arg" =~ ^[0-9]+d$ ]]; then
    local days=${time_arg%d}
    from_epoch=$(date -d "$days days ago 00:00" +%s)
  elif [[ "$time_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    from_epoch=$(date -d "$time_arg 00:00" +%s)
  else
    echo "Error: invalid time range '$time_arg' (use: 2d, 2026-03-18, or omit)" >&2
    return 1
  fi

  # 收集數據
  local json
  json=$(_ccs_recap_collect "$from_epoch" "$scope")

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
```

- [ ] **Step 2: 驗證所有模式**

```bash
source ccs-dashboard.sh

# Terminal 模式（預設）
ccs-recap

# Markdown 模式
ccs-recap --md

# JSON 模式
ccs-recap --json | jq '.summary'

# 指定時間範圍
ccs-recap 3d --md

# 空結果
ccs-recap 2020-01-01

# Help
ccs-recap --help

# 錯誤輸入
ccs-recap invalid_range
# 預期: Error message + return 1
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add ccs-recap main command with terminal/md/json output"
```

---

## Task 7: ccs-orchestrator SKILL.md 更新

**Files:**
- Modify: `skills/ccs-orchestrator/SKILL.md` (lines 33-49 Command Palette, lines 50-70 Routing Rules)

- [ ] **Step 1: 新增 Command Palette 行**

在 Command Palette table（line 49 之前）加入：

```markdown
| recap | rc | `ccs-recap --json` + AI analysis — daily work recap |
```

- [ ] **Step 2: 新增 Routing Rules**

在 Routing Rules section 加入：

```markdown
- "recap", "daily recap", "昨天做了什麼", "早安", "morning", "recap --project" → `recap`
```

- [ ] **Step 3: 新增 Recap 行為說明區塊**

在 SKILL.md 適當位置加入 recap 流程說明：

```markdown
### Recap 流程

1. 執行 `ccs-recap --json` 取得結構化數據
2. 列出有活動的專案，用 `<options>` 問使用者要看哪些（預設全選）
   - YOLO mode 下直接全選，不提問
3. 對每個 pending/in_progress session，用 `_ccs_get_pair` 讀取最後 2-3 對話
4. 輸出分析：
   - 數據摘要
   - 各工作項分析（進展/卡住原因）
   - 優先順序建議（deadline > 卡住需決策 > 接近完成 > 低優先）
5. 用 `<options>` 問：「要升級到完整規劃嗎？」
   - 是 → 生成今日工作計畫（任務/專案/建議時段/說明）
   - 否 → 結束
```

- [ ] **Step 4: Commit**

```bash
git add skills/ccs-orchestrator/SKILL.md
git commit -m "feat: add recap command to ccs-orchestrator skill"
```

---

## Task 8: install.sh + README 更新

**Files:**
- Modify: `install.sh` (line 151)
- Modify: `README.md`

- [ ] **Step 1: 更新 install.sh 指令列表**

在 line 151 附近（available commands list）加入 `ccs-recap`。

- [ ] **Step 2: 更新 README**

在 README.md 的指令列表加入 `ccs-recap` 說明：

```markdown
| `ccs-recap` | 每日工作回顧 — 跨專案 session/todo/feature/git 摘要 |
```

加入用法範例：

```markdown
### Daily Recap

```bash
ccs-recap              # 自動偵測上次工作日
ccs-recap 2d           # 最近 2 天
ccs-recap --json       # JSON（供 skill 層消費）
ccs-recap --project    # 僅當前專案
```
```

- [ ] **Step 3: Commit**

```bash
git add install.sh README.md
git commit -m "docs: add ccs-recap to install.sh and README"
```

---

## Task 9: End-to-end 驗證

- [ ] **Step 1: 完整測試流程**

```bash
# 重新 source
source ccs-dashboard.sh

# 1. 預設模式
ccs-recap

# 2. JSON 驗證 — 確認 skill 層可消費
ccs-recap --json | jq '.projects | length'
ccs-recap --json | jq '.projects[0].sessions[0].todos'

# 3. Markdown 驗證
ccs-recap --md | head -30

# 4. 單專案模式
cd ~/tools/ccs-dashboard && ccs-recap --project

# 5. 時間範圍
ccs-recap 7d

# 6. 空結果 graceful
ccs-recap 2020-01-01

# 7. Help
ccs-recap -h
```

- [ ] **Step 2: 驗證 SKILL.md 語法**

確認 SKILL.md 的 Command Palette table 格式正確（markdown table alignment）。

- [ ] **Step 3: 最終 commit（如有修正）**

```bash
git add -A
git commit -m "fix: address end-to-end test findings for ccs-recap"
```
