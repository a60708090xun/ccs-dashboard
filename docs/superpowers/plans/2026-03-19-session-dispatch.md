# Session Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ccs-dispatch` and `ccs-jobs` commands to ccs-dashboard, enabling task dispatch to Claude Code sessions via `claude -p` with file-based job tracking.

**Architecture:** New functions appended to `ccs-dashboard.sh` following existing patterns. File-based state tracking using JSONL (append-latest-wins) + result files + PID files under `~/.local/share/ccs-dashboard/dispatch/`. Orchestrator skill updated with dispatch/jobs routing.

**Tech Stack:** Bash 4+, jq, coreutils (`timeout`, `find`, `date`)

**Spec:** `docs/superpowers/specs/2026-03-19-session-dispatch-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `ccs-dashboard.sh` (header comment, line 17) | Add `ccs-dispatch`, `ccs-jobs` to command list |
| Modify | `ccs-dashboard.sh` (append after line 3706) | All dispatch functions |
| Modify | `ccs-core.sh:370` (`ccs-cleanup`) | Add dispatch cleanup段 |
| Modify | `skills/ccs-orchestrator/SKILL.md` | Add dispatch/jobs routing |
| Modify | `install.sh` | Add dispatch commands to completion |
| Modify | `README.md` | Document new commands |

---

## Task 1: Configurable Parameters & Data Directory

**Files:**
- Modify: `ccs-dashboard.sh` (append after last function, ~line 3706)

- [ ] **Step 1: Add configurable parameter block**

在 `ccs-dashboard.sh` 末尾（`ccs-recap` 函式之後）加入 dispatch 區段，從 config 變數開始：

```bash
# ══════════════════════════════════════════════════════════════
# ── Session Dispatch: ccs-dispatch + ccs-jobs ──
# ══════════════════════════════════════════════════════════════

# ── Configurable parameters (override via env or .bashrc) ──
CCS_DISPATCH_TIMEOUT=${CCS_DISPATCH_TIMEOUT:-600}
CCS_DISPATCH_JOBS_LIMIT=${CCS_DISPATCH_JOBS_LIMIT:-20}
CCS_DISPATCH_TASK_DISPLAY_LEN=${CCS_DISPATCH_TASK_DISPLAY_LEN:-60}
CCS_DISPATCH_RESULT_TTL_DAYS=${CCS_DISPATCH_RESULT_TTL_DAYS:-7}
CCS_DISPATCH_SUMMARY_LINES=${CCS_DISPATCH_SUMMARY_LINES:-30}
CCS_DISPATCH_SUMMARY_MAX_CHARS=${CCS_DISPATCH_SUMMARY_MAX_CHARS:-200}
CCS_DISPATCH_MAX_CONCURRENT_WARN=${CCS_DISPATCH_MAX_CONCURRENT_WARN:-3}
```

- [ ] **Step 2: Add dispatch data directory helper**

```bash
_ccs_dispatch_dir() {
  local dir
  dir="$(_ccs_data_dir)/dispatch"
  mkdir -p "$dir/results" "$dir/pids"
  echo "$dir"
}
```

- [ ] **Step 3: Add job ID generator**

```bash
_ccs_dispatch_job_id() {
  printf 'd-%s-%04x' "$(date '+%Y%m%d-%H%M%S')" "$((RANDOM % 65536))"
}
```

- [ ] **Step 4: Verify helpers work**

Run:
```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh
_ccs_dispatch_dir
_ccs_dispatch_job_id
```

Expected: directory path printed and created; job ID like `d-20260319-143052-a1b2` printed.

- [ ] **Step 5: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(dispatch): add configurable params, data dir, and job ID helpers"
```

---

## Task 2: JSONL Helpers (Write & Read)

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 1 code)

- [ ] **Step 1: Add JSONL append function**

```bash
_ccs_dispatch_jsonl_append() {
  local dispatch_dir="$1" job_id="$2" project="$3" task="$4"
  local context_injected="$5" mode="$6" status="$7" pid="$8"
  local exit_code="$9" summary="${10}"

  local finished_at="null"
  [ "$status" != "running" ] && finished_at="\"$(date -Iseconds)\""
  [ -z "$exit_code" ] && exit_code="null"
  [ -z "$summary" ] && summary="null" || summary="$(jq -Rsc '.' <<< "$summary")"

  jq -nc \
    --arg job_id "$job_id" \
    --arg project "$project" \
    --arg task "$task" \
    --argjson context "$context_injected" \
    --arg mode "$mode" \
    --arg status "$status" \
    --argjson pid "${pid:-null}" \
    --argjson exit_code "$exit_code" \
    --argjson finished_at "$finished_at" \
    --argjson summary "$summary" \
    --arg created_at "$(date -Iseconds)" \
    '{
      job_id: $job_id, project: $project, task: $task,
      context_injected: $context, mode: $mode, status: $status,
      pid: $pid, created_at: $created_at,
      finished_at: (if $finished_at == null then null else $finished_at end),
      exit_code: $exit_code, summary: $summary
    }' >> "$dispatch_dir/jobs.jsonl"
}
```

- [ ] **Step 2: Add JSONL read function (latest-wins dedup)**

```bash
_ccs_dispatch_jsonl_read() {
  local dispatch_dir="$1"
  local jobs_file="$dispatch_dir/jobs.jsonl"
  [ ! -f "$jobs_file" ] && echo '[]' && return

  # Deduplicate by job_id, keeping last occurrence (append-latest-wins)
  # Sort by job_id (embeds creation timestamp) for stable dispatch-time ordering
  jq -sc '
    group_by(.job_id) | map(last) | sort_by(.job_id) | reverse
  ' "$jobs_file"
}
```

- [ ] **Step 3: Verify JSONL round-trip**

Run:
```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh
dir=$(_ccs_dispatch_dir)
_ccs_dispatch_jsonl_append "$dir" "d-test-001" "/tmp/test" "test task" "false" "async" "running" "99999"
_ccs_dispatch_jsonl_read "$dir" | jq '.[0].job_id'
# cleanup test data
rm "$dir/jobs.jsonl"
```

Expected: `"d-test-001"`

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(dispatch): add JSONL append and read helpers with dedup"
```

---

## Task 3: Context Builder

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 2 code)

- [ ] **Step 1: Add `_ccs_dispatch_context` function**

This helper extracts git status and active session todos for a single project directory, without calling the full `_ccs_overview_json`.

```bash
_ccs_dispatch_context() {
  local project_dir="$1"
  local ctx=""

  ctx+="[Project: $project_dir]"$'\n'

  # Git info (if git repo)
  if [ -d "$project_dir/.git" ]; then
    local branch dirty_count
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    dirty_count=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l)
    ctx+="[Git branch: $branch, uncommitted: $dirty_count files]"$'\n'
  fi

  # Active session todos for this project
  local encoded_dir
  encoded_dir=$(echo "$project_dir" | sed 's|/|-|g')
  local proj_sessions_dir="$HOME/.claude/projects/$encoded_dir"
  if [ -d "$proj_sessions_dir" ]; then
    local todos_found=false
    local todo_lines=""
    local f
    for f in "$proj_sessions_dir"/*.jsonl; do
      [ ! -f "$f" ] && continue
      # Only recent sessions (< 1 day old)
      local mtime now age
      mtime=$(stat -c '%Y' "$f" 2>/dev/null) || continue
      now=$(date +%s)
      age=$(( now - mtime ))
      [ "$age" -gt 86400 ] && continue

      local todos
      todos=$(jq -c '
        select(.type == "assistant") |
        .message.content[]? |
        select(.type == "tool_use" and .name == "TodoWrite") |
        [.input.todos[]? | select(.status != "completed") | "- [ ] " + .content]
      ' "$f" 2>/dev/null | tail -1 | jq -r '.[]?' 2>/dev/null)
      if [ -n "$todos" ]; then
        todos_found=true
        todo_lines+="$todos"$'\n'
      fi
    done
    if $todos_found; then
      ctx+="[Active todos from recent sessions:]"$'\n'
      ctx+="$todo_lines"
    fi
  fi

  ctx+=$'\n---\n'
  echo "$ctx"
}
```

- [ ] **Step 2: Verify context output**

Run:
```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh
_ccs_dispatch_context ~/tools/ccs-dashboard
```

Expected: Project path, git branch/uncommitted info, and any active todos printed.

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(dispatch): add lightweight context builder for single project"
```

---

## Task 4: Lazy Cleanup & Finish Callback

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 3 code)

- [ ] **Step 1: Add lazy cleanup function**

```bash
_ccs_dispatch_lazy_cleanup() {
  local dispatch_dir="$1"
  # Delete result files older than TTL
  find "$dispatch_dir/results" -type f -mtime +"$CCS_DISPATCH_RESULT_TTL_DAYS" -delete 2>/dev/null
  # Clear orphan PID files (process no longer exists)
  local pidfile
  for pidfile in "$dispatch_dir/pids"/*.pid; do
    [ ! -f "$pidfile" ] && continue
    kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || rm -f "$pidfile"
  done
}
```

- [ ] **Step 2: Add finish callback function**

```bash
_ccs_dispatch_finish() {
  local job_id="$1" exit_code="$2"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"

  # Determine status
  local status="completed"
  [ "$exit_code" -eq 124 ] && status="timeout"
  [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 124 ] && status="failed"

  # Extract summary from output
  local summary=""
  local out_file="$dispatch_dir/results/${job_id}.out"
  if [ -f "$out_file" ]; then
    summary=$(tail -n "$CCS_DISPATCH_SUMMARY_LINES" "$out_file" \
      | head -c "$CCS_DISPATCH_SUMMARY_MAX_CHARS")
    # Trim to last complete line if truncated
    if [ ${#summary} -ge "$CCS_DISPATCH_SUMMARY_MAX_CHARS" ]; then
      summary=$(echo "$summary" | sed '$ d')
    fi
  fi

  # Read original job info for append
  local original
  original=$(jq -sc --arg id "$job_id" '
    [.[] | select(.job_id == $id)] | last
  ' "$dispatch_dir/jobs.jsonl")
  local project task context_injected mode
  project=$(echo "$original" | jq -r '.project')
  task=$(echo "$original" | jq -r '.task')
  context_injected=$(echo "$original" | jq -r '.context_injected')
  mode=$(echo "$original" | jq -r '.mode')

  _ccs_dispatch_jsonl_append "$dispatch_dir" "$job_id" "$project" "$task" \
    "$context_injected" "$mode" "$status" "" "$exit_code" "$summary"

  # Remove PID file
  rm -f "$dispatch_dir/pids/${job_id}.pid"
}
```

- [ ] **Step 3: Add lazy status sync (for ccs-jobs)**

```bash
_ccs_dispatch_sync_status() {
  local dispatch_dir="$1"
  local jobs_file="$dispatch_dir/jobs.jsonl"
  [ ! -f "$jobs_file" ] && return

  # Find running jobs and check if their PIDs are still alive
  local running_jobs
  running_jobs=$(jq -sc '
    group_by(.job_id) | map(last) | .[] | select(.status == "running")
  ' "$jobs_file" 2>/dev/null)

  [ -z "$running_jobs" ] && return

  echo "$running_jobs" | while IFS= read -r job; do
    local job_id pid
    job_id=$(echo "$job" | jq -r '.job_id')
    pid=$(echo "$job" | jq -r '.pid // empty')
    [ -z "$pid" ] && continue

    if ! kill -0 "$pid" 2>/dev/null; then
      # Process died without finish callback — mark as failed
      _ccs_dispatch_finish "$job_id" 1
    fi
  done
}
```

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(dispatch): add lazy cleanup, finish callback, and status sync"
```

---

## Task 5: `ccs-dispatch` Main Command

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 4 code)

- [ ] **Step 1: Add `ccs-dispatch` function**

```bash
ccs-dispatch() {
  local sync=false context=false timeout_secs="$CCS_DISPATCH_TIMEOUT"
  local project="" task=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --sync)          sync=true; shift ;;
      --context)       context=true; shift ;;
      --timeout)       timeout_secs="$2"; shift 2 ;;
      --project)       project="$2"; shift 2 ;;
      --help|-h)
        cat <<'HELP'
ccs-dispatch [--sync] [--context] [--timeout <secs>] --project <dir> "task"
[personal tool, not official Claude Code]

Dispatch a task to a new Claude Code session via claude -p.

  --project <dir>   (required) Project directory for claude to work in
  --sync            Wait for result (default: async, returns job-id)
  --context         Inject git status + active todos as prompt prefix
  --timeout <secs>  Task timeout in seconds (default: $CCS_DISPATCH_TIMEOUT)
HELP
        return 0 ;;
      *)
        if [ -z "$task" ]; then
          task="$1"
        else
          echo "Error: unexpected argument '$1'" >&2
          return 1
        fi
        shift ;;
    esac
  done

  # Validate required args
  if [ -z "$project" ]; then
    echo "Error: --project is required" >&2
    return 1
  fi
  if [ -z "$task" ]; then
    echo "Error: task description is required" >&2
    return 1
  fi

  # Validate project directory
  project=$(realpath "$project" 2>/dev/null)
  if [ ! -d "$project" ]; then
    echo "Error: project directory does not exist: $project" >&2
    return 1
  fi
  if $context && [ ! -d "$project/.git" ]; then
    echo "Error: --context requires a git repo, but $project is not" >&2
    return 1
  fi

  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"

  # Lazy cleanup
  _ccs_dispatch_lazy_cleanup "$dispatch_dir"

  # Warn on concurrent jobs
  local running_count
  running_count=$(jq -sc '
    group_by(.job_id) | map(last) | [.[] | select(.status == "running")] | length
  ' "$dispatch_dir/jobs.jsonl" 2>/dev/null || echo 0)
  if [ "$running_count" -ge "$CCS_DISPATCH_MAX_CONCURRENT_WARN" ]; then
    printf '\033[33mWarning: %d jobs already running (threshold: %d)\033[0m\n' \
      "$running_count" "$CCS_DISPATCH_MAX_CONCURRENT_WARN" >&2
  fi

  # Generate job ID
  local job_id
  job_id=$(_ccs_dispatch_job_id)

  # Build prompt
  local prompt=""
  if $context; then
    prompt="$(_ccs_dispatch_context "$project")"
  fi
  prompt+="Task: $task"

  local mode="async"
  $sync && mode="sync"
  local context_json="false"
  $context && context_json="true"

  if $sync; then
    # Synchronous: run and wait
    _ccs_dispatch_jsonl_append "$dispatch_dir" "$job_id" "$project" "$task" \
      "$context_json" "$mode" "running" "$$"

    local exit_code=0
    (cd "$project" && timeout "$timeout_secs" claude -p "$prompt" \
      > "$dispatch_dir/results/${job_id}.out" \
      2> "$dispatch_dir/results/${job_id}.err") || exit_code=$?

    _ccs_dispatch_finish "$job_id" "$exit_code"

    # Print result
    echo "=== Job $job_id ($( [ $exit_code -eq 0 ] && echo 'completed' || echo "exit $exit_code" )) ==="
    cat "$dispatch_dir/results/${job_id}.out"
    if [ -s "$dispatch_dir/results/${job_id}.err" ]; then
      echo "--- stderr ---"
      cat "$dispatch_dir/results/${job_id}.err"
    fi
  else
    # Asynchronous: background and return job ID
    _ccs_dispatch_jsonl_append "$dispatch_dir" "$job_id" "$project" "$task" \
      "$context_json" "$mode" "running" ""

    (
      cd "$project" && timeout "$timeout_secs" claude -p "$prompt" \
        > "$dispatch_dir/results/${job_id}.out" \
        2> "$dispatch_dir/results/${job_id}.err"
      _ccs_dispatch_finish "$job_id" $?
    ) &
    local bg_pid=$!

    # Write PID file and update JSONL with actual PID
    echo "$bg_pid" > "$dispatch_dir/pids/${job_id}.pid"
    _ccs_dispatch_jsonl_append "$dispatch_dir" "$job_id" "$project" "$task" \
      "$context_json" "$mode" "running" "$bg_pid"

    printf 'Job dispatched: %s (PID %d)\n' "$job_id" "$bg_pid"
  fi
}
```

- [ ] **Step 2: Verify help text**

Run:
```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh
ccs-dispatch --help
```

Expected: Help text with all flags displayed.

- [ ] **Step 3: Verify validation**

Run:
```bash
ccs-dispatch "test"
# Expected: Error: --project is required

ccs-dispatch --project /nonexistent "test"
# Expected: Error: project directory does not exist

ccs-dispatch --context --project /tmp "test"
# Expected: Error: --context requires a git repo
```

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(dispatch): add ccs-dispatch command with sync/async modes"
```

---

## Task 6: `ccs-jobs` Command

**Files:**
- Modify: `ccs-dashboard.sh` (append after Task 5 code)

- [ ] **Step 1: Add `ccs-jobs` function**

```bash
ccs-jobs() {
  local show_all=false job_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --all)     show_all=true; shift ;;
      --help|-h)
        cat <<'HELP'
ccs-jobs [--all] [<job-id>]
[personal tool, not official Claude Code]

View dispatch job history and results.

  (no args)     List recent jobs (last N, configurable)
  --all         List all jobs
  <job-id>      Show full result for a specific job
HELP
        return 0 ;;
      *)         job_id="$1"; shift ;;
    esac
  done

  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"

  # Lazy status sync
  _ccs_dispatch_sync_status "$dispatch_dir"

  if [ -n "$job_id" ]; then
    # Show single job detail
    local job
    job=$(jq -sc --arg id "$job_id" '
      [.[] | select(.job_id == $id)] | last // empty
    ' "$dispatch_dir/jobs.jsonl" 2>/dev/null)

    if [ -z "$job" ]; then
      echo "Error: job not found: $job_id" >&2
      return 1
    fi

    local status exit_code project task created finished summary
    status=$(echo "$job" | jq -r '.status')
    exit_code=$(echo "$job" | jq -r '.exit_code // "-"')
    project=$(echo "$job" | jq -r '.project')
    task=$(echo "$job" | jq -r '.task')
    created=$(echo "$job" | jq -r '.created_at')
    finished=$(echo "$job" | jq -r '.finished_at // "running"')

    printf 'Job:      %s\n' "$job_id"
    printf 'Status:   %s (exit %s)\n' "$status" "$exit_code"
    printf 'Project:  %s\n' "$project"
    printf 'Task:     %s\n' "$task"
    printf 'Created:  %s\n' "$created"
    printf 'Finished: %s\n\n' "$finished"

    # Print full result if available
    local out_file="$dispatch_dir/results/${job_id}.out"
    if [ -f "$out_file" ]; then
      echo "=== Output ==="
      cat "$out_file"
      local err_file="$dispatch_dir/results/${job_id}.err"
      if [ -s "$err_file" ]; then
        echo "--- stderr ---"
        cat "$err_file"
      fi
    else
      # Result expired, show summary from JSONL
      summary=$(echo "$job" | jq -r '.summary // "(no summary)"')
      echo "=== Summary (result file expired) ==="
      echo "$summary"
    fi
  else
    # List jobs
    local jobs_json
    jobs_json=$(_ccs_dispatch_jsonl_read "$dispatch_dir")

    local total
    total=$(echo "$jobs_json" | jq 'length')
    if [ "$total" -eq 0 ]; then
      echo "No dispatch jobs found."
      return 0
    fi

    local limit="$CCS_DISPATCH_JOBS_LIMIT"
    $show_all && limit="$total"

    printf '%-28s  %-10s  %-6s  %-20s  %s\n' "JOB-ID" "STATUS" "AGE" "PROJECT" "TASK"
    printf '%-28s  %-10s  %-6s  %-20s  %s\n' "------" "------" "---" "-------" "----"

    echo "$jobs_json" | jq -r --argjson limit "$limit" --argjson display_len "$CCS_DISPATCH_TASK_DISPLAY_LEN" '
      .[:$limit][] |
      [.job_id, .status, .created_at, (.project | split("/") | last), (.task[:$display_len])] |
      @tsv
    ' | while IFS=$'\t' read -r jid status created proj task_short; do
      local age_str
      local created_epoch now_epoch age_secs
      created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      age_secs=$(( now_epoch - created_epoch ))
      if [ "$age_secs" -lt 60 ]; then
        age_str="${age_secs}s"
      elif [ "$age_secs" -lt 3600 ]; then
        age_str="$(( age_secs / 60 ))m"
      elif [ "$age_secs" -lt 86400 ]; then
        age_str="$(( age_secs / 3600 ))h"
      else
        age_str="$(( age_secs / 86400 ))d"
      fi

      printf '%-28s  %-10s  %-6s  %-20s  %s\n' "$jid" "$status" "$age_str" "$proj" "$task_short"
    done

    [ "$total" -gt "$limit" ] && ! $show_all && \
      printf '\n(%d more — use --all to see all)\n' "$(( total - limit ))"
  fi
}
```

- [ ] **Step 2: Verify help text**

Run:
```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh
ccs-jobs --help
```

- [ ] **Step 3: Verify empty state**

Run:
```bash
ccs-jobs
```

Expected: `No dispatch jobs found.` (or list of previously dispatched jobs if any exist)

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(dispatch): add ccs-jobs command for viewing dispatch history"
```

---

## Task 7: Update Header Comment & ccs-cleanup Integration

**Files:**
- Modify: `ccs-dashboard.sh:10-17` (header comment)
- Modify: `ccs-core.sh:370` (`ccs-cleanup` function)

- [ ] **Step 1: Update `ccs-dashboard.sh` header**

Add to the command list (around line 17):

```bash
#   ccs-dispatch        — dispatch task to new Claude Code session
#   ccs-jobs            — view dispatch job history and results
```

- [ ] **Step 2: Add `--dispatch-all` flag and dispatch cleanup to `ccs-cleanup`**

In `ccs-cleanup()` in `ccs-core.sh`, add `--dispatch-all` to the arg parsing (alongside existing `--dry-run` and `--force`):

```bash
      --dispatch-all) dispatch_all=true ;;
```

And add `local dispatch_all=false` at the top with the other flag declarations.

Update the help text to include:
```
  --dispatch-all  Clear ALL dispatch history (jobs.jsonl + results + pids)
```

At the end of `ccs-cleanup()` (before the closing `}`), add a dispatch cleanup section:

```bash
  # ── Dispatch result cleanup ──
  local dispatch_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard/dispatch"
  if [ -d "$dispatch_dir" ]; then
    if $dispatch_all; then
      printf '\n\033[1mDispatch cleanup:\033[0m clearing ALL dispatch history\n'
      if ! $dry_run; then
        rm -f "$dispatch_dir/jobs.jsonl"
        rm -rf "$dispatch_dir/results" "$dispatch_dir/pids"
        mkdir -p "$dispatch_dir/results" "$dispatch_dir/pids"
      fi
    else
      local ttl=${CCS_DISPATCH_RESULT_TTL_DAYS:-7}
      local expired_count
      expired_count=$(find "$dispatch_dir/results" -type f -mtime +"$ttl" 2>/dev/null | wc -l)
      local orphan_pids=0
      local pidfile
      for pidfile in "$dispatch_dir/pids"/*.pid; do
        [ ! -f "$pidfile" ] && continue
        kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || orphan_pids=$((orphan_pids + 1))
      done

      if [ "$expired_count" -gt 0 ] || [ "$orphan_pids" -gt 0 ]; then
        printf '\n\033[1mDispatch cleanup:\033[0m %d expired result(s), %d orphan PID(s)\n' \
          "$expired_count" "$orphan_pids"
        if ! $dry_run; then
          find "$dispatch_dir/results" -type f -mtime +"$ttl" -delete 2>/dev/null
          for pidfile in "$dispatch_dir/pids"/*.pid; do
            [ ! -f "$pidfile" ] && continue
            kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || rm -f "$pidfile"
          done
        fi
      fi
    fi
  fi
```

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh ccs-core.sh
git commit -m "feat(dispatch): update header comment and integrate cleanup"
```

---

## Task 8: Orchestrator Skill Update

**Files:**
- Modify: `skills/ccs-orchestrator/SKILL.md`

- [ ] **Step 1: Add dispatch commands to Command Palette**

在 SKILL.md 的 Command Palette 表格（`| recap | rc |` 行之後）加入：

```markdown
| dispatch --project <dir> "task" | dp | `ccs-dispatch --project <dir> "task"` — 派工（強制非同步） |
| jobs | j | `ccs-jobs` — dispatch 歷史 |
| job <id> | | `ccs-jobs <id>` — 單筆 dispatch 結果 |
```

- [ ] **Step 2: Add routing rules**

在 Routing Rules 段落加入：

```markdown
- 「派工」「dispatch」「跑一下」→ dispatch（直接執行 `ccs-dispatch`，強制非同步）
- 「任務狀態」「dispatch 結果」「jobs」→ jobs
```

- [ ] **Step 3: Add execution rules note**

在 Command Palette 下方或 Routing Rules 段落加入說明：

```markdown
### Dispatch Execution Rules

- `dispatch` (dp)：**直接透過 Bash tool 執行** `ccs-dispatch`（不帶 `--sync`），回傳 job-id
- `jobs` (j) / `job <id>`：**直接執行**，只讀取檔案
- Orchestrator 內一律非同步，`--sync` 僅供 shell 手動使用
```

- [ ] **Step 4: Update context-aware options logic**

在 Context-Aware Options Logic 表格加入相關情境：

```markdown
| 有 dispatch jobs 在 running | 加入「查看 dispatch 狀態」 |
| dispatch job 完成 | 加入「看 job 結果」 |
```

- [ ] **Step 5: Commit**

```bash
git add skills/ccs-orchestrator/SKILL.md
git commit -m "feat(dispatch): add dispatch/jobs routing to orchestrator skill"
```

---

## Task 9: Integration Test

**Files:** None (manual testing)

- [ ] **Step 1: Source and verify all commands exist**

```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh
type ccs-dispatch
type ccs-jobs
```

Expected: Both report as functions.

- [ ] **Step 2: Test async dispatch (dry run with a simple task)**

```bash
ccs-dispatch --project ~/tools/ccs-dashboard "echo hello from dispatch test"
```

Expected: `Job dispatched: d-XXXXXXXX-XXXXXX-XXXX (PID NNNNN)`

- [ ] **Step 3: Wait a moment, then check job status**

```bash
sleep 5
ccs-jobs
```

Expected: Job listed with status (running or completed).

- [ ] **Step 4: Check job detail**

```bash
ccs-jobs d-XXXXXXXX-XXXXXX-XXXX   # use actual job ID from step 2
```

Expected: Full job detail with output shown.

- [ ] **Step 5: Test sync dispatch**

```bash
ccs-dispatch --sync --project ~/tools/ccs-dashboard "list the files in the current directory"
```

Expected: Blocks until done, prints result.

- [ ] **Step 6: Test --context flag**

```bash
ccs-dispatch --sync --context --project ~/tools/ccs-dashboard "summarize the project status based on the context provided"
```

Expected: Context injected (git + todos), result includes project-specific info.

- [ ] **Step 7: Test validation errors**

```bash
ccs-dispatch "test"                           # missing --project
ccs-dispatch --project /nonexistent "test"    # bad path
ccs-dispatch --context --project /tmp "test"  # not git repo
```

Expected: Each prints appropriate error message.

- [ ] **Step 8: Commit any fixes if needed**

---

## Task 10: Update README & install.sh

**Files:**
- Modify: `README.md`
- Modify: `install.sh`

- [ ] **Step 1: Add dispatch commands to README**

在 README 的 commands 段落加入 `ccs-dispatch` 和 `ccs-jobs` 描述，包含用法範例。

- [ ] **Step 2: Update install.sh command list**

在 `install.sh` 的 `do_install()` 指令列表 echo 區塊（約 line 140-153）加入 `ccs-dispatch` 和 `ccs-jobs`。

- [ ] **Step 3: Commit**

```bash
git add README.md install.sh
git commit -m "docs: add ccs-dispatch and ccs-jobs to README and install"
```
