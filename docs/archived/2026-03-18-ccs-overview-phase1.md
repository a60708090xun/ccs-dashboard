# ccs-overview Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 實作 `ccs-overview` 指令，提供跨 session 的工作總覽，支援 terminal ANSI / Markdown / JSON 輸出。

**Architecture:** 在 ccs-core.sh 新增路徑解析 helper `_ccs_resolve_project_path`，在 ccs-dashboard.sh 新增 `ccs-overview` 指令及內部 helpers。ccs-overview 掃描所有 active session 的 JSONL，提取狀態、topic、todos、最近對話摘要、deadline 關鍵字，輸出結構化報告。

**Tech Stack:** Bash 4+, jq, coreutils

**Design Spec:** `docs/specs/2026-03-18-orchestrator-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `ccs-core.sh` | Modify (line ~459) | 新增 `_ccs_resolve_project_path` helper |
| `ccs-dashboard.sh` | Modify (line ~1355) | 新增 `ccs-overview` 指令 + 內部 helpers |

所有新增程式碼加在各檔案尾端，不動現有函式。

---

## Task 1: `_ccs_resolve_project_path` helper

**Files:**
- Modify: `ccs-core.sh:459` (append)

**目的：** 從 JSONL 目錄名（如 `-pool2-chenhsun-tools-ccs-dashboard`）反推實際 filesystem path。現有 `_ccs_session_row` 的 `sed 's/-/\//g'` 無法處理專案名含 `-` 的情況。

- [ ] **Step 1: 實作 `_ccs_resolve_project_path`**

在 ccs-core.sh 尾端新增：

```bash
# ── Helper: resolve JSONL directory name → actual filesystem path ──
# JSONL dirs encode paths as: /pool2/chenhsun/tools/ccs-dashboard → -pool2-chenhsun-tools-ccs-dashboard
# Simple sed 's/-/\//g' fails when project names contain hyphens.
# Strategy: greedy match — try longest path first, progressively split remaining hyphens.
_ccs_resolve_project_path() {
  local encoded="$1"
  [ -z "$encoded" ] && return 1

  # Special case: home directory
  if [ "$encoded" = "-pool2-chenhsun" ]; then
    echo "$HOME"
    return 0
  fi

  # Convert leading dash to slash
  local raw="/${encoded#-}"

  # Try full path as-is (no hyphens in any segment)
  [ -d "$raw" ] && { echo "$raw"; return 0; }

  # Left-to-right greedy: find the longest existing directory prefix,
  # then recurse on the remainder.
  # Split into segments by '-'
  local IFS='-'
  local -a parts=($raw)
  unset IFS

  # Rebuild path greedily: accumulate segments, try extending with '-' first (keep hyphen),
  # then try '/' (split). Prefer longest directory match.
  local resolved=""
  local i=0
  local len=${#parts[@]}

  while [ $i -lt $len ]; do
    # Try extending current segment with hyphen (greedy: keep as many hyphens as possible)
    local candidate="$resolved"
    local best_j=$i
    local j
    for ((j = len; j > i; j--)); do
      # Build candidate from parts[i..j-1] joined with '-'
      local segment="${parts[$i]}"
      local k
      for ((k = i + 1; k < j; k++)); do
        segment="${segment}-${parts[$k]}"
      done
      local try_path
      if [ -z "$resolved" ]; then
        try_path="$segment"
      else
        try_path="${resolved}/${segment}"
      fi
      # Check if this is a valid directory (or final segment)
      if [ -d "$try_path" ]; then
        resolved="$try_path"
        best_j=$j
        break
      fi
    done

    if [ $best_j -eq $i ]; then
      # No match found, just append with /
      if [ -z "$resolved" ]; then
        resolved="${parts[$i]}"
      else
        resolved="${resolved}/${parts[$i]}"
      fi
      i=$((i + 1))
    else
      i=$best_j
    fi
  done

  echo "$resolved"
}
```

- [ ] **Step 2: 驗證 helper**

Run: `source ~/tools/ccs-dashboard/ccs-core.sh && _ccs_resolve_project_path "-pool2-chenhsun-tools-ccs-dashboard" && _ccs_resolve_project_path "-pool2-chenhsun-works-git-specman" && _ccs_resolve_project_path "-pool2-chenhsun"`

Expected:
- `/pool2/chenhsun/tools/ccs-dashboard`
- `/pool2/chenhsun/works/git/specman`（或類似真實路徑）
- `/pool2/chenhsun`

- [ ] **Step 3: Commit**

```bash
git add ccs-core.sh
git commit -m "feat(core): add _ccs_resolve_project_path helper

Resolves JSONL directory names back to filesystem paths.
Handles project names containing hyphens via greedy path matching."
```

---

## Task 2: `ccs-overview` 主框架 + flag parsing

**Files:**
- Modify: `ccs-dashboard.sh:1355` (append)

**目的：** 建立 `ccs-overview` 函式骨架，解析 `--md`、`--json`、`--git`、`--todos-only` 參數，收集 active session 資料到 shell 變數/暫存結構。

- [ ] **Step 1: 實作框架 + session 收集邏輯**

在 ccs-dashboard.sh 尾端新增：

```bash
# ── ccs-overview — cross-session work overview ──
ccs-overview() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-overview  — cross-session work overview
[personal tool, not official Claude Code]

Usage:
  ccs-overview              Terminal ANSI output (default)
  ccs-overview --md         Markdown output (for Skill / Happy web)
  ccs-overview --json       JSON output (for Skill structured parsing)
  ccs-overview --git        Cross-project git status
  ccs-overview --todos-only Cross-session pending todos only
HELP
    return 0
  fi

  local mode="terminal" todos_only=false git_mode=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --md)         mode="md"; shift ;;
      --json)       mode="json"; shift ;;
      --git)        git_mode=true; shift ;;
      --todos-only) todos_only=true; shift ;;
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

    local dir row
    dir=$(basename "$(dirname "$f")")
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
```

- [ ] **Step 2: 驗證 flag parsing**

Run: `source ~/tools/ccs-dashboard/ccs-dashboard.sh && ccs-overview --help`

Expected: 顯示 help text

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(overview): add ccs-overview skeleton with flag parsing

Scans active sessions (non-archived, last 7 days) and dispatches
to mode-specific renderers (--md, --json, --git, --todos-only)."
```

---

## Task 3: `_ccs_overview_session_data` — 單一 session 資料提取

**Files:**
- Modify: `ccs-dashboard.sh` (在 `ccs-overview` 函式之前插入)

**目的：** 從單一 JSONL 提取 overview 需要的所有資料：last exchange、todos、deadline context。輸出 JSON 物件。

- [ ] **Step 1: 實作 `_ccs_overview_session_data`**

```bash
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

  # --- Deadline Context (keyword search across user messages) ---
  local deadline_ctx=""
  deadline_ctx=$(jq -r '
    select(.type == "user" and (.message.content | type == "string")) |
    .message.content
  ' "$jsonl" 2>/dev/null \
    | grep -iE '(deadline|before|週|月底|by |due|urgent|ASAP|趕|今天|明天|後天)' \
    | tail -5 \
    | head -5 \
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
```

- [ ] **Step 2: 驗證**

Run: `source ~/tools/ccs-dashboard/ccs-dashboard.sh && f=$(find ~/.claude/projects -name "*.jsonl" -type f | head -1) && _ccs_overview_session_data "$f" | jq .`

Expected: JSON 物件含 `last_exchange`, `todos`, `deadline_context` 欄位

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(overview): add _ccs_overview_session_data helper

Extracts last exchange, todos, and deadline context from a single
session JSONL for use in ccs-overview output renderers."
```

---

## Task 4: `_ccs_overview_md` — Markdown 輸出

**Files:**
- Modify: `ccs-dashboard.sh` (在 `ccs-overview` 函式之前插入)

**目的：** 實作設計文件中的 Markdown 輸出格式，包含 Active Sessions + Pending Todos + Zombie Processes 三個區塊。

- [ ] **Step 1: 實作 `_ccs_overview_md`**

```bash
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
      # Replace | delimiter back to separate lines
      printf -- '- **Context:** %s\n' "$(echo "$deadline_ctx" | sed 's/|/; /g')"
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
```

- [ ] **Step 2: 驗證**

Run: `source ~/tools/ccs-dashboard/ccs-dashboard.sh && ccs-overview --md`

Expected: 顯示格式正確的 Markdown，包含 Active Sessions、Pending Todos、Zombie Processes 區塊

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(overview): add Markdown output renderer (--md)

Renders cross-session overview with active sessions, last exchange,
todos, deadline context, and zombie process count."
```

---

## Task 5: `_ccs_overview_json` — JSON 輸出

**Files:**
- Modify: `ccs-dashboard.sh` (在 `_ccs_overview_md` 之後插入)

**目的：** 輸出結構化 JSON，欄位與 Markdown 一一對應，供 Skill 做 context-aware 判斷。

- [ ] **Step 1: 實作 `_ccs_overview_json`**

```bash
# ── Helper: render overview as JSON ──
_ccs_overview_json() {
  local -n _files=$1 _projects=$2 _rows=$3
  local count=${#_files[@]}
  local now_str
  now_str=$(date -Iseconds)

  local sessions_json="[]"
  local all_todos_json="[]"
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

    # Build session JSON
    local session_obj
    session_obj=$(jq -nc \
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
      }')

    sessions_json=$(echo "$sessions_json" | jq --argjson s "$session_obj" '. + [$s]')

    # Collect pending todos
    local pending
    pending=$(echo "$data" | jq -c --arg proj "$project" '[.todos[]? | select(.status != "completed") | {content, status, project: $proj}]')
    all_todos_json=$(echo "$all_todos_json" | jq --argjson p "$pending" '. + $p')
  done

  # Zombie count
  local stopped_count
  stopped_count=$(ps -eo pid,stat,comm 2>/dev/null | awk '$2 ~ /T/ && $3 ~ /claude/' | wc -l)

  jq -nc \
    --arg timestamp "$now_str" \
    --argjson sessions "$sessions_json" \
    --argjson pending_todos "$all_todos_json" \
    --argjson zombie_count "$stopped_count" \
    '{
      timestamp: $timestamp,
      active_sessions: ($sessions | length),
      sessions: $sessions,
      pending_todos: $pending_todos,
      zombie_processes: $zombie_count
    }'
}
```

- [ ] **Step 2: 驗證**

Run: `source ~/tools/ccs-dashboard/ccs-dashboard.sh && ccs-overview --json | jq .`

Expected: 格式正確的 JSON，含 `timestamp`, `active_sessions`, `sessions[]`, `pending_todos[]`, `zombie_processes`

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(overview): add JSON output renderer (--json)

Structured JSON output for Skill consumption. Fields mirror the
Markdown format: sessions, pending_todos, zombie_processes."
```

---

## Task 6: `_ccs_overview_todos` — todos-only 模式

**Files:**
- Modify: `ccs-dashboard.sh`

**目的：** 只輸出跨 session 的 pending todos 彙整，不含完整 session 資訊。

- [ ] **Step 1: 實作 `_ccs_overview_todos`**

```bash
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
    local json="[]"
    for entry in "${todo_entries[@]}"; do
      local c p s d
      c=$(echo "$entry" | cut -f1)
      p=$(echo "$entry" | cut -f2)
      s=$(echo "$entry" | cut -f3)
      d=$(echo "$entry" | cut -f4)
      json=$(echo "$json" | jq --arg c "$c" --arg p "$p" --arg s "$s" --arg d "$d" \
        '. + [{content: $c, project: $p, status: $s, deadline_context: (if $d == "" then null else $d end)}]')
    done
    echo "$json" | jq .
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

  printf '| # | Task | Project | Status | Context |\n'
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
```

- [ ] **Step 2: 驗證**

Run: `source ~/tools/ccs-dashboard/ccs-dashboard.sh && ccs-overview --todos-only`

Expected: 只顯示 pending todos 表格（或 "no pending todos" 訊息）

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(overview): add --todos-only mode

Cross-session pending todos summary, supports both Markdown
and JSON output."
```

---

## Task 7: `_ccs_overview_git` — Git 狀態 view

**Files:**
- Modify: `ccs-dashboard.sh`

**目的：** 顯示所有 active session 所屬專案的 git 狀態：branch、uncommitted files、ahead/behind、stash。

- [ ] **Step 1: 實作 `_ccs_overview_git`**

```bash
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
    dirty_count=$(echo "$porcelain" | grep -c '.' || echo 0)
    local modified_count untracked_count
    modified_count=$(echo "$porcelain" | grep -c '^ *[MADRCU]' || echo 0)
    untracked_count=$(echo "$porcelain" | grep -c '^?' || echo 0)

    # Ahead/behind
    ahead=0; behind=0
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
        modified_files=$(echo "$porcelain" | awk '{print $NF}' | head -5 | paste -sd ', ' -)
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
```

- [ ] **Step 2: 驗證**

Run: `source ~/tools/ccs-dashboard/ccs-dashboard.sh && ccs-overview --git`

Expected: 列出各專案 git 狀態，含 branch、uncommitted、ahead/behind

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(overview): add --git cross-project git status view

Shows branch, uncommitted files, ahead/behind, and stash for each
project with active sessions. Supports Markdown and JSON output."
```

---

## Task 8: `_ccs_overview_terminal` — Terminal ANSI 輸出

**Files:**
- Modify: `ccs-dashboard.sh`

**目的：** 預設 terminal 模式，用 ANSI color 顯示精簡總覽（風格與 `ccs-status` 一致）。

- [ ] **Step 1: 實作 `_ccs_overview_terminal`**

```bash
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

    # Brief line: [status] project (age) — topic
    printf '  %b%-25s\033[0m \033[90m%4s\033[0m  %s\n' "$color" "$project" "$ago_str" "$topic"

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
```

- [ ] **Step 2: 驗證**

Run: `source ~/tools/ccs-dashboard/ccs-dashboard.sh && ccs-overview`

Expected: 精簡 ANSI 輸出，每個 session 一行 + optional todo 行

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(overview): add default terminal ANSI output

Compact colored output: one line per session with status color,
project name, age, topic, and in-progress todo if any."
```

---

## Task 9: 更新 header 註解 + README

**Files:**
- Modify: `ccs-dashboard.sh:1-17` (header comment)
- Modify: `ccs-core.sh:1-18` (header comment)

- [ ] **Step 1: 更新 ccs-dashboard.sh header**

在 header comment 的 Commands 區塊加入 `ccs-overview`：

```bash
#   ccs-overview        — cross-session work overview
```

- [ ] **Step 2: 更新 ccs-core.sh header**

在 Helpers 區塊加入：

```bash
#   _ccs_resolve_project_path — resolve JSONL dir name → filesystem path
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh ccs-core.sh
git commit -m "docs: update header comments for ccs-overview and helpers"
```

---

## Task 10: 整合測試

- [ ] **Step 1: 全功能驗證**

依序執行：

```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh

# 1. Terminal 預設
ccs-overview

# 2. Markdown
ccs-overview --md

# 3. JSON（驗證 jq 可解析）
ccs-overview --json | jq .

# 4. Todos only
ccs-overview --todos-only

# 5. Git view
ccs-overview --git

# 6. Help
ccs-overview --help
```

Expected: 所有模式正確輸出，JSON 可被 jq 解析，無 error

- [ ] **Step 2: 邊界情況**

```bash
# 空目錄（backup ~/.claude/projects 後測試）— 略，靠程式碼 review 確認
# 確認 _ccs_resolve_project_path 處理 edge cases
_ccs_resolve_project_path ""        # should return error (exit 1)
_ccs_resolve_project_path "-pool2-chenhsun"  # $HOME
```

- [ ] **Step 3: 修正發現的問題（如果有）**

根據測試結果修正 bug，每個修正單獨 commit。
