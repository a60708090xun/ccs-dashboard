# ccs-crash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ccs-crash` command to auto-detect sessions interrupted by unexpected reboots or process crashes.

**Architecture:** Detection helper `_ccs_detect_crash()` in `ccs-core.sh`, consumed by standalone `ccs-crash` command in `ccs-dashboard.sh` and integrated into `ccs-overview` output. Two detection paths: reboot (uptime comparison) and non-reboot (process liveness).

**Tech Stack:** Bash, jq, standard POSIX utilities (`stat`, `uptime`, `ps`, `kill`)

**Spec:** `docs/superpowers/specs/2026-03-20-crash-detect-design.md`

**Note:** Line numbers reference the original files before modifications. After Task 3 inserts ~150 lines before `ccs-overview`, line numbers in Task 4 will shift accordingly — use function name search, not line numbers.

**Spec deviation:** The spec lists `--json` as a parameter of `_ccs_detect_crash()`. This plan uses a nameref associative array pattern instead (helper produces data, renderers format it), which is a deliberate improvement for separation of concerns. The spec should be updated post-implementation.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `ccs-core.sh` | Modify (after `ccs-cleanup`, ~line 472) | `_ccs_detect_crash()` helper + `_ccs_get_boot_epoch()` helper |
| `ccs-dashboard.sh` | Modify (after `ccs-tag`, ~line 3075) | `ccs-crash` command |
| `ccs-dashboard.sh` | Modify (`_ccs_overview_md`, `_ccs_overview_json`, `ccs-overview`) | Crash detection integration |
| `docs/commands.md` | Modify | Document `ccs-crash` command |
| `tests/test-crash-detect.sh` | Create | Manual verification script |

---

### Task 1: Boot Epoch Helper

**Files:**
- Modify: `ccs-core.sh` (after line 472, before `_ccs_resolve_project_path`)

- [ ] **Step 1: Add `_ccs_get_boot_epoch()` helper**

```bash
# ── Helper: get system boot time as epoch ──
# Returns epoch via stdout. Returns 1 if unavailable (e.g., containers).
_ccs_get_boot_epoch() {
  local boot_str
  # Primary: uptime -s
  boot_str=$(uptime -s 2>/dev/null)
  if [ -n "$boot_str" ]; then
    date -d "$boot_str" +%s 2>/dev/null && return 0
  fi
  # Fallback: who -b
  boot_str=$(who -b 2>/dev/null | awk '{print $3, $4}')
  if [ -n "$boot_str" ]; then
    date -d "$boot_str" +%s 2>/dev/null && return 0
  fi
  return 1
}
```

- [ ] **Step 2: Verify helper works**

Run: `source ccs-core.sh && _ccs_get_boot_epoch && echo "OK: $(date -d @$(_ccs_get_boot_epoch))"`
Expected: prints boot time matching `uptime -s`

- [ ] **Step 3: Commit**

```bash
git add ccs-core.sh
git commit -m "feat(crash): add _ccs_get_boot_epoch helper

Extracts system boot time as epoch. Primary: uptime -s, fallback: who -b.
Returns 1 if both unavailable (containers).

ref #9"
```

---

### Task 2: Core Detection Helper

**Files:**
- Modify: `ccs-core.sh` (after `_ccs_get_boot_epoch`)

- [ ] **Step 1: Add `_ccs_detect_crash()` helper**

This is the core detection logic. It populates a nameref associative array with `session_id → confidence:path` entries.

```bash
# ── Helper: detect crash-interrupted sessions ──
# Usage: declare -A crash_map; _ccs_detect_crash crash_map [--reboot-window N] [--idle-window N] [files_array] [projects_array]
# crash_map[session_id] = "high:reboot" | "high:non-reboot" | "low:non-reboot"
_ccs_detect_crash() {
  local -n _crash_out=$1; shift
  local reboot_window=30 idle_window=1440

  while [ $# -gt 0 ]; do
    case "$1" in
      --reboot-window) reboot_window="$2"; shift 2 ;;
      --idle-window) idle_window="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  # Remaining args: files_array_name projects_array_name
  # Use a flag to track standalone mode and avoid double nameref
  local _standalone=false
  local -a _standalone_files=() _standalone_projects=() _standalone_rows=()
  if [ $# -ge 2 ]; then
    local -n _cd_files=$1 _cd_projects=$2
  else
    _standalone=true
    _ccs_collect_sessions _standalone_files _standalone_projects _standalone_rows
    local -n _cd_files=_standalone_files _cd_projects=_standalone_projects
  fi

  local now=$(date +%s)
  local boot_epoch
  if ! boot_epoch=$(_ccs_get_boot_epoch); then
    boot_epoch=0
    echo "ccs-crash: warning: cannot determine boot time (container?), Path 1 disabled" >&2
  fi

  local reboot_window_start=0 reboot_upper=0
  if [ "$boot_epoch" -gt 0 ]; then
    reboot_window_start=$((boot_epoch - reboot_window * 60))
    reboot_upper=$((boot_epoch + 120))
  fi

  local idle_window_start=$((now - idle_window * 60))

  # Path 2: get list of running claude session IDs (once)
  local running_sids=""
  running_sids=$(ps -eo args 2>/dev/null | grep -oP '(?<=--resume )[0-9a-f-]{36}' | sort -u)

  local count=${#_cd_files[@]}
  local i
  for ((i = 0; i < count; i++)); do
    local f="${_cd_files[$i]}"
    [ -f "$f" ] || continue

    local mtime sid
    mtime=$(stat -c "%Y" "$f" 2>/dev/null) || continue
    sid=$(basename "$f" .jsonl)

    # Path 1: Reboot detection
    if [ "$boot_epoch" -gt 0 ] && [ "$mtime" -ge "$reboot_window_start" ] && [ "$mtime" -lt "$reboot_upper" ]; then
      _crash_out["$sid"]="high:reboot"
      continue
    fi

    # Path 2: Non-reboot detection
    # Skip if mtime outside idle window or after boot (already running post-reboot)
    [ "$mtime" -ge "$idle_window_start" ] || continue
    [ "$boot_epoch" -eq 0 ] || [ "$mtime" -ge "$reboot_upper" ] || continue

    # Check if process is still running
    echo "$running_sids" | grep -q "$sid" && continue

    # Check for interrupt signals in last assistant message (raw JSONL)
    # Last assistant message: content array with no text entries = mid-execution crash
    local has_text
    has_text=$(tac "$f" 2>/dev/null | grep -m1 '"type":"assistant"' | jq -r '
      if .message.content then
        ([.message.content[] | select(.type == "text" and (.text | length > 0))] | length)
      else
        0
      end
    ' 2>/dev/null)

    if [ "${has_text:-0}" = "0" ]; then
      _crash_out["$sid"]="high:non-reboot"
    else
      _crash_out["$sid"]="low:non-reboot"
    fi
  done
}
```

- [ ] **Step 2: Verify Path 1 detection**

Run: `source ccs-dashboard.sh && declare -A cm; _ccs_detect_crash cm --reboot-window 180; for k in "${!cm[@]}"; do echo "$k → ${cm[$k]}"; done`

Use `--reboot-window 180` (3 hours) to catch today's crash. Expected: sessions active before 09:47 are flagged as `high:reboot`.

- [ ] **Step 3: Verify Path 2 detection with narrow window**

Run: `source ccs-dashboard.sh && declare -A cm; _ccs_detect_crash cm --reboot-window 0 --idle-window 1440; for k in "${!cm[@]}"; do echo "$k → ${cm[$k]}"; done`

Disable Path 1 (`--reboot-window 0`), check that Path 2 catches dead sessions with `high:non-reboot` or `low:non-reboot`.

- [ ] **Step 4: Commit**

```bash
git add ccs-core.sh
git commit -m "feat(crash): add _ccs_detect_crash detection helper

Two detection paths:
- Path 1 (reboot): mtime in [boot-window, boot+120s) → high confidence
- Path 2 (non-reboot): dead process + JSONL signal analysis → high/low

Uses nameref associative array for zero-copy result passing.

ref #9"
```

---

### Task 3: `ccs-crash` Command

**Files:**
- Modify: `ccs-dashboard.sh` (after `ccs-tag`, ~line 3075)

- [ ] **Step 1: Add `ccs-crash` command with `--help`**

```bash
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
      --help|-h)
        cat <<'HELP'
ccs-crash  — detect sessions interrupted by crash or unexpected reboot
[personal tool, not official Claude Code]

Usage:
  ccs-crash                  Markdown output, high confidence only (default)
  ccs-crash --json           JSON output
  ccs-crash --all            Include low confidence + subagent sessions
  ccs-crash --reboot-window N  Path 1 window in minutes (default: 30)
  ccs-crash --idle-window N    Path 2 window in minutes (default: 1440)

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
  if ! $show_all; then
    for sid in "${!crash_map[@]}"; do
      [[ "${crash_map[$sid]}" == low:* ]] && unset 'crash_map[$sid]'
    done
  fi

  if [ ${#crash_map[@]} -eq 0 ]; then
    echo "No crash-interrupted sessions detected."
    return 0
  fi

  case "$mode" in
    md)   _ccs_crash_md crash_map session_files session_projects session_rows ;;
    json) _ccs_crash_json crash_map session_files session_projects session_rows "$reboot_window" "$idle_window" ;;
  esac
}
```

- [ ] **Step 2: Add `_ccs_crash_md()` renderer**

```bash
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
    local last_user last_assistant
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

    echo "### $icon $sid — $project — $topic"
    echo "- **Confidence:** $confidence ($path)"
    echo "- **最後活動：** $last_time（${ago_min}m ago）"
    echo "- **最後訊息：** $last_user"
    [ -n "$todo_summary" ] && echo "- **Todos：** $todo_summary"
    [ -n "$git_branch" ] && echo "- **Git：** $git_branch ($git_dirty uncommitted files)"
    echo "- **Resume：** \`claude --resume $sid\`"
    echo ""
  done
}
```

- [ ] **Step 3: Add `_ccs_crash_json()` renderer**

```bash
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
```

- [ ] **Step 4: Verify `ccs-crash --md`**

Run: `source ccs-dashboard.sh && ccs-crash --reboot-window 180`
Expected: Markdown output listing sessions interrupted by today's crash.

- [ ] **Step 5: Verify `ccs-crash --json`**

Run: `source ccs-dashboard.sh && ccs-crash --json --reboot-window 180 | jq .`
Expected: Valid JSON with `boot_time` and `sessions` array.

- [ ] **Step 6: Verify `ccs-crash --all`**

Run: `source ccs-dashboard.sh && ccs-crash --all --reboot-window 180`
Expected: Additional low confidence sessions shown with 🟡 icon.

- [ ] **Step 7: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(crash): add ccs-crash command with md/json output

Standalone command for crash-interrupted session detection.
Supports --reboot-window, --idle-window, --all, --md, --json.
Renders session details including last message, todos, git status,
and resume command.

ref #9"
```

---

### Task 4: Overview Integration

**Files:**
- Modify: `ccs-dashboard.sh` (`ccs-overview` at ~line 3078, `_ccs_overview_md`, `_ccs_overview_json`)

- [ ] **Step 1: Add crash detection call in `ccs-overview()`**

In `ccs-overview()`, after `_ccs_collect_sessions` (line 3115) and before the mode dispatch, add:

```bash
  # Crash detection (high confidence only, for overview banner)
  local -A crash_map=()
  _ccs_detect_crash crash_map session_files session_projects
```

Update the full overview dispatch to pass `crash_map`:

```bash
  # Full overview
  case "$mode" in
    md)       _ccs_overview_md session_files session_projects session_rows crash_map ;;
    json)     _ccs_overview_json session_files session_projects session_rows crash_map ;;
    terminal) _ccs_overview_terminal session_files session_projects session_rows crash_map ;;
  esac
```

- [ ] **Step 2: Add crash banner in `_ccs_overview_md()`**

After the `# Work Overview` header line, add:

```bash
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
    [ "$boot_epoch" -gt 0 ] && boot_str=$(date -d "@$boot_epoch" '+%H:%M')
    echo ""
    echo "> **偵測到 ${crash_high} 個 crash-interrupted session**（系統重開機 ${boot_str}）"
    echo "> 執行 \`ccs-crash\` 查看詳情，或 \`ccs-crash --all\` 含低信心結果"
    echo ""
  fi
```

In the per-session loop, override status icon for crash-interrupted sessions:

```bash
    # Override status icon if crash-interrupted (high confidence)
    local sid=$(basename "$f" .jsonl)
    if [ -n "${_crash_md[$sid]+x}" ] && [[ "${_crash_md[$sid]}" == high:* ]]; then
      status_icon="🔴"
    fi
```

- [ ] **Step 3: Add crash fields in `_ccs_overview_json()`**

Add `crash_detected` top-level field and per-session `crash_interrupted`/`crash_confidence` fields. After building the sessions array:

```bash
  # crash_detected field (4th arg is optional)
  local crash_high_sids=()
  if [ -n "${4:-}" ]; then
    local -n _crash_json=$4
  fi
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
```

In the per-session JSON builder, add crash fields:

```bash
    local crash_interrupted=false crash_confidence=""
    local full_sid=$(basename "$f" .jsonl)
    if [ -n "${4:-}" ] && [ -n "${_crash_json[$full_sid]+x}" ]; then
      crash_interrupted=true
      crash_confidence="${_crash_json[$full_sid]%%:*}"
    fi
```

- [ ] **Step 4: Verify overview banner**

Run: `source ccs-dashboard.sh && ccs-overview --md | head -10`
Expected: Banner line showing crash-interrupted count if any sessions match.

- [ ] **Step 5: Verify overview JSON**

Run: `source ccs-dashboard.sh && ccs-overview --json | jq '.crash_detected'`
Expected: Object with `boot_time`, `affected_sessions`, `count` — or `null` if no crash detected.

- [ ] **Step 6: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(crash): integrate crash detection into ccs-overview

- Add crash banner in --md output when high confidence sessions found
- Add crash_detected top-level field in --json output
- Override session status icon to 🔴 for crash-interrupted sessions
- Per-session crash_interrupted and crash_confidence in JSON

ref #9"
```

---

### Task 5: Update Header Comments and Documentation

**Files:**
- Modify: `ccs-core.sh` (header comment block, lines 1-22)
- Modify: `docs/commands.md`

- [ ] **Step 1: Update `ccs-core.sh` header**

Add the new helpers and update the Commands list:

```bash
#   _ccs_get_boot_epoch     — system boot time as epoch
#   _ccs_detect_crash       — detect crash-interrupted sessions
```

- [ ] **Step 2: Update `docs/commands.md`**

Add `ccs-crash` entry with usage, options, detection paths, confidence levels, and examples.

- [ ] **Step 3: Commit**

```bash
git add ccs-core.sh docs/commands.md
git commit -m "docs: add ccs-crash to header comments and commands.md

ref #9"
```

---

### Task 6: Manual Verification Script

**Files:**
- Create: `tests/test-crash-detect.sh`

- [ ] **Step 1: Write verification script**

```bash
#!/usr/bin/env bash
# Manual verification for ccs-crash (GitHub #9)
# Run: bash tests/test-crash-detect.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/ccs-dashboard.sh"

echo "=== Test 1: _ccs_get_boot_epoch ==="
boot=$(_ccs_get_boot_epoch) && echo "PASS: boot epoch=$boot ($(date -d @$boot))" || echo "FAIL: no boot epoch"

echo ""
echo "=== Test 2: _ccs_detect_crash (default windows) ==="
declare -A cm1=()
_ccs_detect_crash cm1
echo "Detected: ${#cm1[@]} sessions"
for k in "${!cm1[@]}"; do echo "  $k → ${cm1[$k]}"; done
# Sanity: helper should run without error
echo "PASS: helper completed without error"

echo ""
echo "=== Test 3: _ccs_detect_crash (wide reboot window) ==="
declare -A cm2=()
_ccs_detect_crash cm2 --reboot-window 180
echo "Detected: ${#cm2[@]} sessions"
for k in "${!cm2[@]}"; do echo "  $k → ${cm2[$k]}"; done

echo ""
echo "=== Test 4: ccs-crash --md ==="
ccs-crash --reboot-window 180 2>/dev/null || true

echo ""
echo "=== Test 5: ccs-crash --json (valid JSON check) ==="
output=$(ccs-crash --json --reboot-window 180 2>/dev/null)
echo "$output" | jq . >/dev/null 2>&1 && echo "PASS: valid JSON" || echo "FAIL: invalid JSON"

echo ""
echo "=== Test 6: ccs-overview --md (crash banner check) ==="
ccs-overview --md 2>/dev/null | head -6

echo ""
echo "=== Test 7: ccs-overview --json (crash_detected field) ==="
ccs-overview --json 2>/dev/null | jq '.crash_detected' 2>/dev/null || echo "FAIL: no crash_detected field"

echo ""
echo "=== Test 8: ccs-crash --help ==="
ccs-crash --help >/dev/null 2>&1 && echo "PASS" || echo "FAIL"

echo ""
echo "=== All tests complete ==="
```

- [ ] **Step 2: Run verification script**

Run: `bash tests/test-crash-detect.sh`
Expected: All 8 tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/test-crash-detect.sh
git commit -m "test: add manual verification script for ccs-crash

ref #9"
```

---

### Task 7: Final Review and Cleanup

- [ ] **Step 1: Run full test suite**

```bash
bash tests/test-crash-detect.sh
```

- [ ] **Step 2: Test edge case — no crash detected**

Wait until system has been up for a while, then run with `--reboot-window 1`:

```bash
source ccs-dashboard.sh && ccs-crash --reboot-window 1
```

Expected: "No crash-interrupted sessions detected."

- [ ] **Step 3: Verify overview with no crash**

```bash
source ccs-dashboard.sh && ccs-overview --md | head -5
```

Expected: No crash banner.

- [ ] **Step 4: Code review (dispatch superpowers:code-reviewer)**

Review all changes against the spec.

- [ ] **Step 5: Final commit if needed, then mark ready for merge**
