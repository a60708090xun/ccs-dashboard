# ccs-checkpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ccs-checkpoint` command — a lightweight, flexible time-slice progress snapshot with Done / In Progress / Blocked columns, for standup recaps and pre-meeting updates.

**Architecture:** New functions appended to `ccs-dashboard.sh` after `ccs-recap` (line 3736). Follows existing patterns: parse args → collect data as JSON → render terminal/markdown. Timestamp persistence via flat file in `~/.local/share/ccs-dashboard/`.

**Tech Stack:** Bash 4+, jq, coreutils (`date`, `stat`, `find`)

**Spec:** `docs/specs/2026-03-20-ccs-checkpoint-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `ccs-dashboard.sh` (append after line 3736) | All checkpoint functions |
| Modify | `install.sh:160` (after ccs-recap) | Add `ccs-checkpoint` to commands list |

---

## Task 1: `_ccs_checkpoint_parse_since` — 時間解析

**Files:**
- Modify: `ccs-dashboard.sh` (append after line 3736)

- [ ] **Step 1: Add checkpoint section header and parse_since function**

在 `ccs-dashboard.sh` 末尾加入：

```bash
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
```

- [ ] **Step 2: Smoke test parse_since**

```bash
source ccs-dashboard.sh
# Test cases
_ccs_checkpoint_parse_since "9:00" && echo OK
_ccs_checkpoint_parse_since "yesterday" && echo OK
_ccs_checkpoint_parse_since "2h ago" && echo OK
_ccs_checkpoint_parse_since "30m ago" && echo OK
_ccs_checkpoint_parse_since "2026-03-20" && echo OK
_ccs_checkpoint_parse_since "2026-03-20T09:00" && echo OK
_ccs_checkpoint_parse_since "garbage" && echo BUG || echo "rejected OK"
```

Expected: 6 OK + 1 "rejected OK"

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(checkpoint): add _ccs_checkpoint_parse_since time parser"
```

---

## Task 2: `_ccs_checkpoint_collect` — 資料收集與三欄分類

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 1)

- [ ] **Step 1: Add _ccs_checkpoint_collect function**

此函式掃描 sessions 並分類為 Done / In Progress / Blocked，輸出 JSON。結構參考 `_ccs_recap_collect`（line 3202）的 inner loop。

```bash
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
    local proj_name=${proj_path##*/}
    local session_dir="$HOME/.claude/projects/$proj_dir"

    while IFS= read -r jsonl; do
      local mtime
      mtime=$(stat -c %Y "$jsonl" 2>/dev/null) || continue
      (( mtime < since_epoch )) && continue

      local sid topic is_archived age_min
      sid=$(basename "$jsonl" .jsonl)
      topic=$(_ccs_topic_from_jsonl "$jsonl")
      age_min=$(( (now_epoch - mtime) / 60 ))

      # Check archived
      is_archived=false
      if tail -20 "$jsonl" 2>/dev/null | grep -q '"type":"last-prompt"'; then
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
      [ -z "$todos_json" ] && todos_json="[]"
      local todo_count
      todo_count=$(echo "$todos_json" | jq 'length')

      # Check blocked: inactive > 2h OR keyword match
      local is_blocked=false
      if (( age_min > 120 )); then
        is_blocked=true
      else
        if jq -r 'select(.type == "user" and (.message.content | type == "string") and ((.isMeta // false) == false)) | .message.content' "$jsonl" 2>/dev/null \
          | tail -5 \
          | grep -qiE '(blocked|卡住|等待|waiting|stuck)'; then
          is_blocked=true
        fi
      fi

      local entry
      entry=$(jq -nc --arg p "$proj_name" --arg t "$topic" --arg s "$sid" \
        --argjson todos "$todos_json" --argjson tc "$todo_count" \
        '{project: $p, topic: $t, session: $s, todos: $todos, todo_count: $tc}')

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
```

- [ ] **Step 2: Smoke test collect**

```bash
source ccs-dashboard.sh
since=$(date -d "today 00:00" +%s)
_ccs_checkpoint_collect "$since" "all" | jq .
```

Expected: JSON with done/in_progress/blocked arrays and summary counts.

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(checkpoint): add _ccs_checkpoint_collect data collector"
```

---

## Task 3: `_ccs_checkpoint_terminal` — Terminal 輸出

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 2)

- [ ] **Step 1: Add terminal renderer**

```bash
# _ccs_checkpoint_terminal — render checkpoint as ANSI terminal output
# $1: JSON from _ccs_checkpoint_collect
_ccs_checkpoint_terminal() {
  local json="$1"
  local since now
  since=$(echo "$json" | jq -r '.since')
  now=$(echo "$json" | jq -r '.now')

  printf '\033[1;36m━━ Checkpoint (%s → %s) ━━\033[0m\n\n' "$since" "$now"

  # Done
  printf '\033[1;32m✅ Done\033[0m\n'
  local d_count
  d_count=$(echo "$json" | jq '.done | length')
  if (( d_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '.done[] | "  \(.project)  \(.topic)"'
  fi

  echo
  # In Progress
  printf '\033[1;33m🔄 In Progress\033[0m\n'
  local w_count
  w_count=$(echo "$json" | jq '.in_progress | length')
  if (( w_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '.in_progress[] | "  \(.project)  \(.topic)", (.todos[]? | "    - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi

  echo
  # Blocked
  printf '\033[1;31m⚠️  Blocked\033[0m\n'
  local b_count
  b_count=$(echo "$json" | jq '.blocked | length')
  if (( b_count == 0 )); then
    printf '  \033[90m(none)\033[0m\n'
  else
    echo "$json" | jq -r '.blocked[] | "  \(.project)  \(.topic)", (.todos[]? | "    - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi

  echo
  local total
  total=$(echo "$json" | jq '.summary.total')
  printf '\033[90m── %d sessions · %d done · %d in progress · %d blocked ──\033[0m\n' \
    "$total" "$d_count" "$w_count" "$b_count"
}
```

- [ ] **Step 2: Smoke test terminal output**

```bash
source ccs-dashboard.sh
since=$(date -d "today 00:00" +%s)
json=$(_ccs_checkpoint_collect "$since" "all")
_ccs_checkpoint_terminal "$json"
```

Expected: formatted ANSI output with 3 columns.

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(checkpoint): add _ccs_checkpoint_terminal renderer"
```

---

## Task 4: `_ccs_checkpoint_md` + `_ccs_checkpoint_table` — Markdown 輸出

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 3)

- [ ] **Step 1: Add markdown list renderer**

```bash
# _ccs_checkpoint_md — render checkpoint as markdown list
# $1: JSON from _ccs_checkpoint_collect
_ccs_checkpoint_md() {
  local json="$1"
  local since now
  since=$(echo "$json" | jq -r '.since')
  now=$(echo "$json" | jq -r '.now')

  printf '## Checkpoint (%s → %s)\n\n' "$since" "$now"

  printf '### Done\n'
  local d_count
  d_count=$(echo "$json" | jq '.done | length')
  if (( d_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '.done[] | "- **\(.project)** — \(.topic)"'
  fi

  printf '\n### In Progress\n'
  local w_count
  w_count=$(echo "$json" | jq '.in_progress | length')
  if (( w_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '.in_progress[] | "- **\(.project)** — \(.topic)", (.todos[]? | "  - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi

  printf '\n### Blocked\n'
  local b_count
  b_count=$(echo "$json" | jq '.blocked | length')
  if (( b_count == 0 )); then
    printf -- '- (none)\n'
  else
    echo "$json" | jq -r '.blocked[] | "- **\(.project)** — \(.topic)", (.todos[]? | "  - [\(if .status == "in_progress" then "~" else " " end)] \(.content)")' 2>/dev/null
  fi
  echo
}
```

- [ ] **Step 2: Add markdown table renderer**

```bash
# _ccs_checkpoint_table — render checkpoint as markdown table
# $1: JSON from _ccs_checkpoint_collect
_ccs_checkpoint_table() {
  local json="$1"
  local since now
  since=$(echo "$json" | jq -r '.since')
  now=$(echo "$json" | jq -r '.now')

  printf '## Checkpoint (%s → %s)\n\n' "$since" "$now"
  printf '| %s | %s | %s |\n' "狀態" "專案" "項目"
  printf '|------|------|------|\n'

  echo "$json" | jq -r '
    (.done[] | "| Done | \(.project) | \(.topic) |"),
    (.in_progress[] | "| WIP | \(.project) | \(.topic)\(if .todo_count > 0 then " (\(.todo_count) todos)" else "" end) |"),
    (.blocked[] | "| Blocked | \(.project) | \(.topic)\(if .todo_count > 0 then " (\(.todo_count) todos)" else "" end) |")
  ' 2>/dev/null

  local total
  total=$(echo "$json" | jq '.summary.total')
  (( total == 0 )) && printf '| - | - | (none) |\n'
  echo
}
```

- [ ] **Step 3: Smoke test both markdown renderers**

```bash
source ccs-dashboard.sh
since=$(date -d "today 00:00" +%s)
json=$(_ccs_checkpoint_collect "$since" "all")
echo "=== List ==="
_ccs_checkpoint_md "$json"
echo "=== Table ==="
_ccs_checkpoint_table "$json"
```

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(checkpoint): add markdown list and table renderers"
```

---

## Task 5: `ccs-checkpoint` — 主入口

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 4)

- [ ] **Step 1: Add main entry function**

```bash
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
  local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard"
  local ts_file="$data_dir/last-checkpoint"

  if [ -n "$since_arg" ]; then
    since_epoch=$(_ccs_checkpoint_parse_since "$since_arg") || return 1
  elif [ -f "$ts_file" ]; then
    since_epoch=$(cat "$ts_file")
  else
    since_epoch=$(date -d "today 00:00" +%s)
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
    mkdir -p "$data_dir"
    date +%s > "$ts_file"
  fi
}
```

- [ ] **Step 2: End-to-end test**

```bash
source ccs-dashboard.sh
ccs-checkpoint --help
ccs-checkpoint
ccs-checkpoint --since "8h ago"
ccs-checkpoint --md
ccs-checkpoint --md --table
ccs-checkpoint --project
```

Verify: all modes produce output, `--table` without `--md` falls through to terminal mode.

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(checkpoint): add ccs-checkpoint main entry with all output modes"
```

---

## Task 6: install.sh 更新

**Files:**
- Modify: `install.sh:157` (commands list)

- [ ] **Step 1: Add ccs-checkpoint to install.sh commands list**

在 `install.sh` 的 `Commands available:` 區塊中加入：

```bash
  echo "  ccs-checkpoint      — progress snapshot (done/wip/blocked)"
```

加在 `ccs-recap` 之後（如果有的話），或 `ccs-overview` 之後。

- [ ] **Step 2: Syntax check**

```bash
bash -n install.sh && echo OK
```

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat(checkpoint): add ccs-checkpoint to install.sh commands list"
```
