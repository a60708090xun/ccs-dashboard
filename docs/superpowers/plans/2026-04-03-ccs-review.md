# ccs-review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a session review system that generates progress reports (markdown/HTML/PDF) from Claude Code session JSONL data, with optional LLM-generated summaries.

**Architecture:** Bash data layer (`ccs-review.sh`) extracts stats and conversation from JSONL into a JSON intermediate format. Python render layer (`ccs-review-render.py`) converts JSON to HTML via Jinja2 templates. LLM summaries are generated via Claude Code subagent and cached locally.

**Tech Stack:** Bash + jq (data layer), Python 3 + Jinja2 (HTML render), weasyprint (PDF, Step 5)

**Spec:** `docs/superpowers/specs/2026-04-03-ccs-review-design.md`

---

## File Structure

```
ccs-review.sh              # New bash module — data extraction + JSON/markdown output
ccs-review-render.py       # Python script — JSON → HTML via Jinja2
templates/
  review.html              # Single-session HTML template
  review-weekly.html       # Weekly report HTML template (Step 4)
tests/
  test-review.sh           # Unit tests for ccs-review.sh functions
```

**Existing files to modify:**
- `ccs-dashboard.sh:27` — add `source ccs-review.sh` after `ccs-dispatch.sh`
- `install.sh` — add python3, jinja2, weasyprint dependency checks
- `skills/ccs-orchestrator/SKILL.md` — add `ccs-review` routing

---

## Step 1: CLI + Markdown Output

### Task 1.1: Tool Use Aggregation Function

**Files:**
- Create: `ccs-review.sh`
- Test: `tests/test-review.sh`

- [ ] **Step 1: Create test file with tool use aggregation tests**

Create `tests/test-review.sh`:

```bash
#!/usr/bin/env bash
# tests/test-review.sh — ccs-review.sh function tests
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh
source ccs-review.sh

setup_test_dir "review"

echo "=== _ccs_tool_use_stats: tool counting ==="

# Case A: mixed tool usage
A="$TEST_DIR/mixed-tools.jsonl"
cat > "$A" <<'JSONL'
{"type":"user","message":{"content":"fix the bug"},"timestamp":"2026-04-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.sh"}},{"type":"tool_use","name":"Read","input":{"file_path":"/b.sh"}},{"type":"text","text":"I see the issue."}]},"timestamp":"2026-04-01T10:01:00Z"}
{"type":"user","message":{"content":"ok fix it"},"timestamp":"2026-04-01T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a.sh","old_string":"x","new_string":"y"}},{"type":"tool_use","name":"Bash","input":{"command":"pytest"}},{"type":"text","text":"Fixed and tested."}]},"timestamp":"2026-04-01T10:03:00Z"}
JSONL

stats=$(_ccs_tool_use_stats "$A")
assert_eq "A: Read count" "2" "$(echo "$stats" | jq -r '.Read')"
assert_eq "A: Edit count" "1" "$(echo "$stats" | jq -r '.Edit')"
assert_eq "A: Bash count" "1" "$(echo "$stats" | jq -r '.Bash')"
assert_eq "A: Write absent" "null" "$(echo "$stats" | jq -r '.Write')"

# Case B: empty session (no tool use)
B="$TEST_DIR/empty.jsonl"
cat > "$B" <<'JSONL'
{"type":"user","message":{"content":"hello"},"timestamp":"2026-04-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hi!"}]},"timestamp":"2026-04-01T10:01:00Z"}
JSONL

stats=$(_ccs_tool_use_stats "$B")
assert_eq "B: empty tools" "{}" "$stats"

test_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `ccs-review.sh: No such file` or `_ccs_tool_use_stats: command not found`

- [ ] **Step 3: Create ccs-review.sh with tool use aggregation**

Create `ccs-review.sh`:

```bash
#!/usr/bin/env bash
# ccs-review.sh — Session review: data extraction + report generation
# Part of ccs-dashboard. Sourced by ccs-dashboard.sh automatically.
#
# Functions:
#   _ccs_tool_use_stats     — tool use count aggregation from JSONL
#   _ccs_session_stats      — full session statistics as JSON
#   _ccs_review_json        — complete review data as JSON
#   ccs-review              — CLI entry point
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-review.sh tests/test-review.sh
git commit -m "feat(review): add tool use aggregation function"
```

---

### Task 1.2: Session Statistics JSON

**Files:**
- Modify: `ccs-review.sh`
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add session stats tests**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== _ccs_session_stats: full stats ==="

C="$TEST_DIR/stats-session.jsonl"
cat > "$C" <<'JSONL'
{"type":"user","message":{"content":"implement login"},"timestamp":"2026-04-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.py"}},{"type":"text","text":"Reading the file."}]},"timestamp":"2026-04-01T10:05:00Z"}
{"type":"user","message":{"content":"looks good, proceed"},"timestamp":"2026-04-01T10:10:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a.py","old_string":"x","new_string":"y"}},{"type":"tool_use","name":"Bash","input":{"command":"pytest"}},{"type":"text","text":"Done and tested."}]},"timestamp":"2026-04-01T10:30:00Z"}
JSONL

stats_json=$(_ccs_session_stats "$C")
assert_eq "C: rounds" "2" "$(echo "$stats_json" | jq -r '.rounds')"
assert_eq "C: duration" "30" "$(echo "$stats_json" | jq -r '.duration_min')"
assert_eq "C: tool Read" "1" "$(echo "$stats_json" | jq -r '.tool_use.Read')"
assert_eq "C: has char_count" "true" "$(echo "$stats_json" | jq 'has("char_count")')"
assert_eq "C: has token_estimate" "true" "$(echo "$stats_json" | jq 'has("token_estimate")')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `_ccs_session_stats: command not found`

- [ ] **Step 3: Implement _ccs_session_stats**

Append to `ccs-review.sh`:

```bash
# ── Helper: compute full session statistics ──
# Output: JSON with rounds, duration, char_count, token_estimate, tool_use
_ccs_session_stats() {
  local jsonl="$1"

  # Rounds: count user prompts (string content, not tool_result)
  local rounds
  rounds=$(jq -s '[.[] | select(.type == "user" and (.message.content | type == "string"))] | length' "$jsonl" 2>/dev/null)

  # Time range: first and last timestamps
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

  # Character count: all user + assistant text
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

  # Token estimate: Chinese ~1.5 char/token, English ~4 char/token
  # Rough: assume mixed → 2.5 char/token average
  local token_estimate=$(( char_count * 10 / 25 ))

  # Tool use stats
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-review.sh tests/test-review.sh
git commit -m "feat(review): add session stats extraction"
```

---

### Task 1.3: Full Review JSON Output

**Files:**
- Modify: `ccs-review.sh`
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add review JSON tests**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== _ccs_review_json: full JSON output ==="

D="$TEST_DIR/review-session.jsonl"
cat > "$D" <<'JSONL'
{"type":"user","message":{"content":"add dark mode"},"timestamp":"2026-04-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/style.css"}},{"type":"text","text":"I see the current styles."}]},"timestamp":"2026-04-01T10:01:00Z"}
{"type":"user","message":{"content":"go ahead"},"timestamp":"2026-04-01T10:05:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/style.css","old_string":"bg: white","new_string":"bg: var(--bg)"}},{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Add dark mode toggle","status":"completed"},{"content":"Test on mobile","status":"pending"}]}},{"type":"text","text":"Done."}]},"timestamp":"2026-04-01T10:20:00Z"}
JSONL

# Use a fake session path to test
review_json=$(_ccs_review_json "$D")
assert_eq "D: has session_id" "true" "$(echo "$review_json" | jq 'has("session_id")')"
assert_eq "D: has stats" "true" "$(echo "$review_json" | jq 'has("stats")')"
assert_eq "D: has conversation" "true" "$(echo "$review_json" | jq 'has("conversation")')"
assert_eq "D: conversation length" "2" "$(echo "$review_json" | jq '.conversation | length')"
assert_eq "D: todos length" "2" "$(echo "$review_json" | jq '.todos | length')"
assert_eq "D: summary is null" "null" "$(echo "$review_json" | jq -r '.summary')"
assert_contains "D: recent_files has Read" "$(echo "$review_json" | jq -r '.recent_files[]')" "R /style.css"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `_ccs_review_json: command not found`

- [ ] **Step 3: Implement _ccs_review_json**

Append to `ccs-review.sh`:

```bash
# ── Helper: build complete review JSON for a session ──
# Output: JSON matching the schema in the design spec
_ccs_review_json() {
  local jsonl="$1"
  local sid
  sid=$(basename "$jsonl" .jsonl)

  # Project path from directory name
  local dir project
  dir=$(basename "$(dirname "$jsonl")")
  project=$(_ccs_resolve_project_path "$dir" 2>/dev/null || echo "$dir")

  # Model: extract from first assistant message
  local model
  model=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$jsonl" 2>/dev/null | head -1)
  [ -z "$model" ] && model="unknown"

  # Topic
  local topic
  topic=$(_ccs_topic_from_jsonl "$jsonl")

  # Stats
  local stats
  stats=$(_ccs_session_stats "$jsonl")

  # Todos
  local todos
  todos=$(_ccs_todos_md "$jsonl")
  local todos_json
  todos_json=$(echo "$todos" | awk '
    /^\- \[x\]/ { gsub(/^- \[x\] /, ""); printf "{\"status\":\"completed\",\"content\":\"%s\"}\n", $0 }
    /^\- \[~\]/ { gsub(/^- \[~\] /, ""); printf "{\"status\":\"in_progress\",\"content\":\"%s\"}\n", $0 }
    /^\- \[ \]/ { gsub(/^- \[ \] /, ""); printf "{\"status\":\"pending\",\"content\":\"%s\"}\n", $0 }
  ' | jq -s '.' 2>/dev/null)
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
  local cache_dir
  cache_dir="$(_ccs_data_dir)/review-cache"
  local cache_file="$cache_dir/${sid}.summary.json"
  if [ -f "$cache_file" ]; then
    # Check 24h validity
    local cache_age
    cache_age=$(( ($(date +%s) - $(stat -c "%Y" "$cache_file")) / 3600 ))
    if [ "$cache_age" -lt 24 ]; then
      summary=$(cat "$cache_file")
    fi
  fi

  # Git state (if project dir exists)
  local git_json='{"branch":"","recent_commits":[]}'
  if [ -d "$project" ] && [ -d "$project/.git" ]; then
    local branch recent_commits
    branch=$(git -C "$project" branch --show-current 2>/dev/null || echo "")
    recent_commits=$(git -C "$project" log --oneline -5 2>/dev/null | jq -Rs 'split("\n") | map(select(length > 0))')
    git_json=$(jq -n --arg b "$branch" --argjson c "$recent_commits" '{branch: $b, recent_commits: $c}')
  fi

  # Assemble final JSON
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-review.sh tests/test-review.sh
git commit -m "feat(review): add full review JSON output"
```

---

### Task 1.4: Markdown Rendering

**Files:**
- Modify: `ccs-review.sh`
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add markdown rendering test**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== _ccs_review_md: markdown output ==="

# Reuse fixture D from above
md_output=$(_ccs_review_json "$D" | _ccs_review_md)
assert_contains "D-md: has title" "$md_output" "# Session Review"
assert_contains "D-md: has stats" "$md_output" "回合"
assert_contains "D-md: has conversation" "$md_output" "add dark mode"
assert_contains "D-md: has todos" "$md_output" "Add dark mode toggle"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `_ccs_review_md: command not found`

- [ ] **Step 3: Implement _ccs_review_md**

Append to `ccs-review.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-review.sh tests/test-review.sh
git commit -m "feat(review): add markdown rendering"
```

---

### Task 1.5: CLI Entry Point + Integration

**Files:**
- Modify: `ccs-review.sh`
- Modify: `ccs-dashboard.sh:27`
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add CLI integration test**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== ccs-review: CLI entry point ==="

# Create a fake project structure for testing
FAKE_PROJECTS="$TEST_DIR/projects"
mkdir -p "$FAKE_PROJECTS/test-project"
cp "$D" "$FAKE_PROJECTS/test-project/abc12345-fake-session.jsonl"

# Test --format json with explicit file
cli_json=$(CCS_PROJECTS_DIR="$FAKE_PROJECTS" ccs-review abc12345 --format json 2>/dev/null)
assert_eq "CLI: json format has session_id" "true" "$(echo "$cli_json" | jq 'has("session_id")')"

# Test --format md
cli_md=$(CCS_PROJECTS_DIR="$FAKE_PROJECTS" ccs-review abc12345 --format md 2>/dev/null)
assert_contains "CLI: md has title" "$cli_md" "Session Review"

# Test --no-summary flag
cli_nosummary=$(CCS_PROJECTS_DIR="$FAKE_PROJECTS" ccs-review abc12345 --format json --no-summary 2>/dev/null)
assert_eq "CLI: no-summary forces null" "null" "$(echo "$cli_nosummary" | jq -r '.summary')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `ccs-review: command not found`

- [ ] **Step 3: Implement ccs-review CLI entry point**

Append to `ccs-review.sh`:

```bash
# ── ccs-review — session review report ──
ccs-review() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-review [session_id] [options]  — generate session review report

Options:
  --format md|json|html   Output format (default: md)
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

  # Parse arguments
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
  local jsonl
  jsonl=$(_ccs_resolve_jsonl "$session_id" "true")
  if [ -z "$jsonl" ] || [ ! -f "$jsonl" ]; then
    echo "Error: session not found: ${session_id:-<latest>}" >&2
    return 1
  fi

  # Generate JSON
  local review_json
  review_json=$(_ccs_review_json "$jsonl")

  # Strip summary if --no-summary
  if $no_summary; then
    review_json=$(echo "$review_json" | jq '.summary = null')
  fi

  # Output
  case "$format" in
    json)
      echo "$review_json"
      ;;
    md)
      echo "$review_json" | _ccs_review_md
      ;;
    html)
      local outfile
      local slug topic_slug date_slug
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
    *)
      echo "Unknown format: $format" >&2
      return 1
      ;;
  esac
}
```

- [ ] **Step 4: Add source line to ccs-dashboard.sh**

In `ccs-dashboard.sh`, after line 27 (`source "${BASH_SOURCE[0]%/*}/ccs-dispatch.sh"`), add:

```bash
source "${BASH_SOURCE[0]%/*}/ccs-review.sh"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 6: Run full test suite**

Run: `bash tests/run-all.sh`
Expected: All existing tests still pass

- [ ] **Step 7: Commit**

```bash
git add ccs-review.sh ccs-dashboard.sh tests/test-review.sh
git commit -m "feat(review): add CLI entry point and integrate into dashboard"
```

---

## Step 2: LLM Summary (via Subagent + Cache)

### Task 2.1: Cache Read/Write Functions

**Files:**
- Modify: `ccs-review.sh`
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add cache function tests**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== _ccs_review_cache: read/write ==="

# Override data dir for testing
FAKE_DATA="$TEST_DIR/data"
mkdir -p "$FAKE_DATA"
_ccs_data_dir() { echo "$FAKE_DATA"; }

test_sid="test-session-id"
test_summary='{"completions":["Did X"],"suggestions":["Try Y"],"generated_at":"2026-04-01T12:00:00Z"}'

# Write cache
_ccs_review_cache_write "$test_sid" "$test_summary"
assert_eq "cache: file exists" "true" "$([ -f "$FAKE_DATA/review-cache/${test_sid}.summary.json" ] && echo true || echo false)"

# Read cache (should succeed — just written)
cached=$(_ccs_review_cache_read "$test_sid")
assert_eq "cache: read matches" "Did X" "$(echo "$cached" | jq -r '.completions[0]')"

# Read nonexistent cache
missing=$(_ccs_review_cache_read "nonexistent-id")
assert_eq "cache: missing returns empty" "" "$missing"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `_ccs_review_cache_write: command not found`

- [ ] **Step 3: Implement cache functions**

Add to `ccs-review.sh` (after `_ccs_tool_use_stats`):

```bash
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
```

- [ ] **Step 4: Update `_ccs_review_json` to use `_ccs_review_cache_read`**

In `_ccs_review_json`, replace the inline cache logic with:

```bash
  # LLM summary cache
  local summary="null"
  local cached_summary
  cached_summary=$(_ccs_review_cache_read "$sid")
  if [ -n "$cached_summary" ]; then
    summary="$cached_summary"
  fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add ccs-review.sh tests/test-review.sh
git commit -m "feat(review): add LLM summary cache read/write"
```

---

### Task 2.2: Skill Layer — ccs-orchestrator Routing

**Files:**
- Modify: `skills/ccs-orchestrator/SKILL.md`

- [ ] **Step 1: Read current skill file**

Read `skills/ccs-orchestrator/SKILL.md` to understand current routing structure.

- [ ] **Step 2: Add ccs-review routing**

Add `ccs-review` to the command routing section. The skill should:
1. Route "review this session" / "session review" / "ccs-review" to the review workflow
2. Call `ccs-review <sid> --format json` to get structured data
3. Extract conversation from JSON
4. Dispatch subagent with the completion + suggestion prompts
5. Parse subagent output into `completions` and `suggestions` arrays
6. Call `_ccs_review_cache_write` to save
7. Call `ccs-review <sid> --format html -o <path>` for final output

The exact prompt templates are in the spec (§7). The skill should include them verbatim.

- [ ] **Step 3: Test manually**

In a Claude Code session, say "review this session" and verify:
- JSON data is extracted correctly
- Subagent generates completions + suggestions
- Cache file is written
- Final output (md or html) includes the summary

- [ ] **Step 4: Commit**

```bash
git add skills/ccs-orchestrator/SKILL.md
git commit -m "feat(review): add ccs-review routing to orchestrator skill"
```

---

## Step 3: HTML Rendering

### Task 3.1: Python Render Script Setup

**Files:**
- Create: `ccs-review-render.py`
- Modify: `install.sh`

- [ ] **Step 1: Install jinja2**

Run: `pip3 install --user jinja2`

- [ ] **Step 2: Create ccs-review-render.py**

```python
#!/usr/bin/env python3
"""ccs-review-render.py — Render review JSON to HTML via Jinja2.

Usage: echo '{"session_id":...}' | python3 ccs-review-render.py
       echo '{"range":...}' | python3 ccs-review-render.py --weekly

Reads JSON from stdin, outputs HTML to stdout.
"""
import sys
import json
import os
from pathlib import Path

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    print("Error: jinja2 not installed. Run: pip3 install jinja2", file=sys.stderr)
    sys.exit(1)


def main():
    script_dir = Path(__file__).parent
    template_dir = script_dir / "templates"

    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        autoescape=True,
    )

    data = json.load(sys.stdin)

    weekly = "--weekly" in sys.argv
    template_name = "review-weekly.html" if weekly else "review.html"
    template = env.get_template(template_name)

    html = template.render(**data)
    print(html)


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Add jinja2 check to install.sh**

In `install.sh` `check_deps()` function, add after the python3 check:

```bash
  # jinja2 (for ccs-review HTML rendering)
  if python3 -c "import jinja2" 2>/dev/null; then
    ok "jinja2 $(python3 -c 'import jinja2; print(jinja2.__version__)')"
  else
    warn "jinja2 not found — optional, for ccs-review --format html"
    warn "  Install: pip3 install --user jinja2"
  fi
```

- [ ] **Step 4: Commit**

```bash
git add ccs-review-render.py install.sh
git commit -m "feat(review): add Python render script and jinja2 dependency"
```

---

### Task 3.2: HTML Template — Structure + Stats Panel

**Files:**
- Create: `templates/review.html`

- [ ] **Step 1: Create templates directory**

Run: `mkdir -p templates`

- [ ] **Step 2: Create review.html template**

Create `templates/review.html`:

```html
<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Session Review: {{ topic }}</title>
<style>
  :root {
    --bg: #0d1117;
    --fg: #c9d1d9;
    --card-bg: #161b22;
    --border: #30363d;
    --accent: #58a6ff;
    --green: #3fb950;
    --yellow: #d29922;
    --user-bg: #1a3a5c;
    --asst-bg: #1c2333;
    --badge-bg: #21262d;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    background: var(--bg); color: var(--fg);
    max-width: 900px; margin: 0 auto; padding: 20px;
    line-height: 1.6;
  }
  h1 { color: var(--accent); margin-bottom: 4px; font-size: 1.5em; }
  .meta { color: #8b949e; margin-bottom: 20px; font-size: 0.9em; }
  .card {
    background: var(--card-bg); border: 1px solid var(--border);
    border-radius: 8px; padding: 16px; margin-bottom: 16px;
  }
  .card h2 { font-size: 1.1em; margin-bottom: 12px; color: var(--accent); }
  .stats-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 12px;
  }
  .stat-item { text-align: center; }
  .stat-value { font-size: 1.5em; font-weight: bold; color: var(--green); }
  .stat-label { font-size: 0.8em; color: #8b949e; }
  .tool-bar { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  .tool-badge {
    background: var(--badge-bg); border: 1px solid var(--border);
    border-radius: 4px; padding: 4px 8px; font-size: 0.8em;
  }
  .tool-count { color: var(--accent); font-weight: bold; }

  /* Summary sections */
  .summary-list { list-style: none; padding: 0; }
  .summary-list li { padding: 4px 0; }
  .summary-list li::before { content: "•"; color: var(--accent); margin-right: 8px; }

  /* Collapsible sections */
  details { margin-bottom: 8px; }
  summary {
    cursor: pointer; padding: 8px 12px;
    background: var(--card-bg); border: 1px solid var(--border);
    border-radius: 6px; font-weight: bold;
  }
  summary:hover { border-color: var(--accent); }
  details[open] > summary { border-radius: 6px 6px 0 0; }
  .details-content {
    background: var(--card-bg); border: 1px solid var(--border);
    border-top: none; border-radius: 0 0 6px 6px; padding: 12px;
  }

  /* Chat bubbles */
  .chat { display: flex; flex-direction: column; gap: 12px; }
  .bubble { max-width: 85%; padding: 12px 16px; border-radius: 12px; }
  .bubble-user {
    align-self: flex-end; background: var(--user-bg);
    border-bottom-right-radius: 4px;
  }
  .bubble-asst {
    align-self: flex-start; background: var(--asst-bg);
    border-bottom-left-radius: 4px;
  }
  .bubble-label {
    font-size: 0.75em; color: #8b949e; margin-bottom: 4px;
  }
  .bubble-text {
    white-space: pre-wrap; word-break: break-word; font-size: 0.9em;
  }
  .bubble-text.collapsed { max-height: 200px; overflow: hidden; position: relative; }
  .bubble-text.collapsed::after {
    content: ""; position: absolute; bottom: 0; left: 0; right: 0;
    height: 60px; background: linear-gradient(transparent, var(--asst-bg));
  }
  .bubble-user .bubble-text.collapsed::after {
    background: linear-gradient(transparent, var(--user-bg));
  }
  .expand-btn {
    background: none; border: 1px solid var(--border); color: var(--accent);
    padding: 4px 12px; border-radius: 4px; cursor: pointer; margin-top: 8px;
    font-size: 0.8em;
  }
  .bubble-tools { margin-top: 8px; display: flex; flex-wrap: wrap; gap: 4px; }
  .bubble-tool {
    font-size: 0.7em; background: var(--badge-bg); padding: 2px 6px;
    border-radius: 3px; color: #8b949e;
  }

  /* Todos */
  .todo-list { list-style: none; padding: 0; }
  .todo-list li { padding: 2px 0; }
  .todo-done { text-decoration: line-through; color: #8b949e; }

  /* Responsive */
  @media (max-width: 600px) {
    body { padding: 10px; }
    .stats-grid { grid-template-columns: repeat(2, 1fr); }
    .bubble { max-width: 95%; }
  }
</style>
</head>
<body>

<h1>Session Review: {{ topic }}</h1>
<p class="meta">{{ project }} — {{ time_range.start[:10] }} — {{ model }}</p>

{# LLM Summary (only if present) #}
{% if summary %}
<div class="card">
  <h2>完成項目</h2>
  <ul class="summary-list">
    {% for item in summary.completions %}
    <li>{{ item }}</li>
    {% endfor %}
  </ul>
</div>
{% endif %}

{# Stats Panel #}
<div class="card">
  <h2>統計</h2>
  <div class="stats-grid">
    <div class="stat-item">
      <div class="stat-value">{{ time_range.duration_min }}</div>
      <div class="stat-label">分鐘</div>
    </div>
    <div class="stat-item">
      <div class="stat-value">{{ stats.rounds }}</div>
      <div class="stat-label">回合</div>
    </div>
    <div class="stat-item">
      <div class="stat-value">{{ "{:,}".format(stats.char_count) }}</div>
      <div class="stat-label">字數</div>
    </div>
    <div class="stat-item">
      <div class="stat-value">~{{ "{:,}".format(stats.token_estimate) }}</div>
      <div class="stat-label">Token（粗估）</div>
    </div>
  </div>
  <div class="tool-bar">
    {% for tool, count in stats.tool_use.items() %}
    <span class="tool-badge">{{ tool }} <span class="tool-count">×{{ count }}</span></span>
    {% endfor %}
  </div>
</div>

{# LLM Suggestions (only if present) #}
{% if summary and summary.suggestions %}
<div class="card">
  <h2>改善建議</h2>
  <ul class="summary-list">
    {% for item in summary.suggestions %}
    <li>{{ item }}</li>
    {% endfor %}
  </ul>
</div>
{% endif %}

{# Todos (collapsible) #}
{% if todos %}
<details>
  <summary>任務進度（{{ todos | length }} 項）</summary>
  <div class="details-content">
    <ul class="todo-list">
      {% for todo in todos %}
      <li class="{{ 'todo-done' if todo.status == 'completed' else '' }}">
        {% if todo.status == 'completed' %}☑{% elif todo.status == 'in_progress' %}⏳{% else %}☐{% endif %}
        {{ todo.content }}
      </li>
      {% endfor %}
    </ul>
  </div>
</details>
{% endif %}

{# Recent files (collapsible) #}
{% if recent_files %}
<details>
  <summary>涉及檔案（{{ recent_files | length }} 項）</summary>
  <div class="details-content">
    {% for f in recent_files %}
    <div style="font-family: monospace; font-size: 0.85em; padding: 2px 0;">{{ f }}</div>
    {% endfor %}
  </div>
</details>
{% endif %}

{# Conversation (collapsible, chat bubbles) #}
{% if conversation %}
<details>
  <summary>完整對話紀錄（{{ conversation | length }} 回合）</summary>
  <div class="details-content">
    <div class="chat">
      {% for pair in conversation %}
      <div class="bubble bubble-user">
        <div class="bubble-label">User [{{ pair.index }}]</div>
        <div class="bubble-text {{ 'collapsed' if pair.user | length > 500 else '' }}"
             id="user-{{ pair.index }}">{{ pair.user }}</div>
        {% if pair.user | length > 500 %}
        <button class="expand-btn" onclick="toggleExpand('user-{{ pair.index }}', this)">展開全文</button>
        {% endif %}
      </div>
      <div class="bubble bubble-asst">
        <div class="bubble-label">Claude [{{ pair.index }}]</div>
        <div class="bubble-text {{ 'collapsed' if pair.assistant | length > 500 else '' }}"
             id="asst-{{ pair.index }}">{{ pair.assistant }}</div>
        {% if pair.assistant | length > 500 %}
        <button class="expand-btn" onclick="toggleExpand('asst-{{ pair.index }}', this)">展開全文</button>
        {% endif %}
        {% if pair.tools %}
        <div class="bubble-tools">
          {% for tool in pair.tools %}
          <span class="bubble-tool">{{ tool }}</span>
          {% endfor %}
        </div>
        {% endif %}
      </div>
      {% endfor %}
    </div>
  </div>
</details>
{% endif %}

<script>
function toggleExpand(id, btn) {
  const el = document.getElementById(id);
  el.classList.toggle('collapsed');
  btn.textContent = el.classList.contains('collapsed') ? '展開全文' : '收合';
}
</script>

<p style="text-align:center; color:#8b949e; font-size:0.75em; margin-top:24px;">
  Generated by ccs-dashboard · {{ time_range.start[:10] }}
</p>

</body>
</html>
```

- [ ] **Step 3: Commit**

```bash
git add templates/review.html
git commit -m "feat(review): add single-session HTML template"
```

---

### Task 3.3: End-to-End HTML Test

**Files:**
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add HTML rendering E2E test**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== HTML rendering: end-to-end ==="

# Check jinja2 availability
if python3 -c "import jinja2" 2>/dev/null; then
  html_output=$(_ccs_review_json "$D" | python3 "$(cd "$(dirname "$0")/.." && pwd)/ccs-review-render.py")
  assert_contains "HTML: has doctype" "$html_output" "<!DOCTYPE html>"
  assert_contains "HTML: has topic" "$html_output" "add dark mode"
  assert_contains "HTML: has stats" "$html_output" "回合"
  assert_contains "HTML: has chat bubble" "$html_output" "bubble-user"
else
  echo "  SKIP: jinja2 not installed"
fi
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS (or SKIP if jinja2 not installed)

- [ ] **Step 3: Manual visual test**

Run against a real session:
```bash
source ccs-dashboard.sh
ccs-review --format html -o /tmp/
```
Open the HTML file in a browser. Check:
- Stats panel renders correctly
- Chat bubbles layout (user right, assistant left)
- Long messages collapse with "展開全文" button
- Mobile responsive (resize browser to < 600px)

- [ ] **Step 4: Commit**

```bash
git add tests/test-review.sh
git commit -m "test(review): add HTML rendering E2E test"
```

---

## Step 4: Weekly Report Mode

### Task 4.1: Multi-Session Collection

**Files:**
- Modify: `ccs-review.sh`
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add weekly collection test**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== _ccs_review_weekly_collect: date range ==="

# Create multiple sessions with different timestamps
WEEKLY_DIR="$TEST_DIR/weekly-projects/test-proj"
mkdir -p "$WEEKLY_DIR"

# Session in range
W1="$WEEKLY_DIR/sess-in-range.jsonl"
cat > "$W1" <<'JSONL'
{"type":"user","message":{"content":"task A"},"timestamp":"2026-03-25T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done A."}]},"timestamp":"2026-03-25T10:30:00Z"}
JSONL
touch -d "2026-03-25 10:30:00" "$W1"

# Session out of range (too old)
W2="$WEEKLY_DIR/sess-too-old.jsonl"
cat > "$W2" <<'JSONL'
{"type":"user","message":{"content":"task B"},"timestamp":"2026-03-20T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done B."}]},"timestamp":"2026-03-20T10:30:00Z"}
JSONL
touch -d "2026-03-20 10:30:00" "$W2"

collected=$(CCS_PROJECTS_DIR="$TEST_DIR/weekly-projects" _ccs_review_weekly_collect "2026-03-24" "2026-03-31")
assert_contains "weekly: includes in-range" "$collected" "sess-in-range"
assert_not_contains "weekly: excludes too-old" "$collected" "sess-too-old"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `_ccs_review_weekly_collect: command not found`

- [ ] **Step 3: Implement weekly collection**

Add to `ccs-review.sh`:

```bash
# ── Helper: collect JSONL files within date range ──
# Output: one JSONL path per line
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-review.sh tests/test-review.sh
git commit -m "feat(review): add weekly session collection by date range"
```

---

### Task 4.2: Weekly JSON + Aggregate Stats

**Files:**
- Modify: `ccs-review.sh`
- Modify: `tests/test-review.sh`

- [ ] **Step 1: Add weekly JSON test**

Append to `tests/test-review.sh` (before `test_summary`):

```bash
echo "=== _ccs_review_weekly_json: aggregate ==="

weekly_json=$(CCS_PROJECTS_DIR="$TEST_DIR/weekly-projects" _ccs_review_weekly_json "2026-03-24" "2026-03-31")
assert_eq "weekly: has range" "2026-03-24" "$(echo "$weekly_json" | jq -r '.range.since')"
assert_eq "weekly: session count" "1" "$(echo "$weekly_json" | jq '.aggregate_stats.total_sessions')"
assert_eq "weekly: has sessions array" "true" "$(echo "$weekly_json" | jq 'has("sessions")')"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-review.sh`
Expected: FAIL — `_ccs_review_weekly_json: command not found`

- [ ] **Step 3: Implement weekly JSON**

Add to `ccs-review.sh`:

```bash
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

  # Aggregate tool use
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
```

- [ ] **Step 4: Implement _ccs_review_weekly dispatcher**

Add to `ccs-review.sh`:

```bash
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-review.sh`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add ccs-review.sh tests/test-review.sh
git commit -m "feat(review): add weekly report mode with aggregate stats"
```

---

### Task 4.3: Weekly HTML Template

**Files:**
- Create: `templates/review-weekly.html`

- [ ] **Step 1: Create weekly template**

Create `templates/review-weekly.html`. It reuses the same CSS variables and style patterns from `review.html`, but with:

- Header: date range instead of session topic
- Aggregate stats panel (same grid layout)
- Aggregate tool use bar
- Weekly summary section (if `weekly_summary` is not null)
- Sessions list: each session as a `<details>` card with individual stats + summary

```html
<!DOCTYPE html>
<html lang="zh-TW">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>週報 {{ range.since }} ~ {{ range.until }}</title>
<style>
  /* Same :root vars and base styles as review.html */
  :root {
    --bg: #0d1117; --fg: #c9d1d9; --card-bg: #161b22;
    --border: #30363d; --accent: #58a6ff; --green: #3fb950;
    --badge-bg: #21262d;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    background: var(--bg); color: var(--fg);
    max-width: 900px; margin: 0 auto; padding: 20px; line-height: 1.6;
  }
  h1 { color: var(--accent); margin-bottom: 4px; font-size: 1.5em; }
  .meta { color: #8b949e; margin-bottom: 20px; font-size: 0.9em; }
  .card {
    background: var(--card-bg); border: 1px solid var(--border);
    border-radius: 8px; padding: 16px; margin-bottom: 16px;
  }
  .card h2 { font-size: 1.1em; margin-bottom: 12px; color: var(--accent); }
  .stats-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px;
  }
  .stat-item { text-align: center; }
  .stat-value { font-size: 1.5em; font-weight: bold; color: var(--green); }
  .stat-label { font-size: 0.8em; color: #8b949e; }
  .tool-bar { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  .tool-badge {
    background: var(--badge-bg); border: 1px solid var(--border);
    border-radius: 4px; padding: 4px 8px; font-size: 0.8em;
  }
  .tool-count { color: var(--accent); font-weight: bold; }
  .summary-list { list-style: none; padding: 0; }
  .summary-list li { padding: 4px 0; }
  .summary-list li::before { content: "•"; color: var(--accent); margin-right: 8px; }
  details { margin-bottom: 8px; }
  summary {
    cursor: pointer; padding: 8px 12px;
    background: var(--card-bg); border: 1px solid var(--border);
    border-radius: 6px; font-weight: bold;
  }
  summary:hover { border-color: var(--accent); }
  details[open] > summary { border-radius: 6px 6px 0 0; }
  .details-content {
    background: var(--card-bg); border: 1px solid var(--border);
    border-top: none; border-radius: 0 0 6px 6px; padding: 12px;
  }
  .session-meta { color: #8b949e; font-size: 0.85em; margin-bottom: 8px; }
  @media (max-width: 600px) {
    body { padding: 10px; }
    .stats-grid { grid-template-columns: repeat(2, 1fr); }
  }
</style>
</head>
<body>

<h1>週報 {{ range.since }} ~ {{ range.until }}</h1>
<p class="meta">{{ aggregate_stats.total_sessions }} sessions</p>

{# Weekly LLM Summary (if present) #}
{% if weekly_summary %}
<div class="card">
  <h2>本週亮點</h2>
  <ul class="summary-list">
    {% for item in weekly_summary.highlights %}
    <li>{{ item }}</li>
    {% endfor %}
  </ul>
</div>
{% endif %}

{# Aggregate Stats #}
<div class="card">
  <h2>總覽</h2>
  <div class="stats-grid">
    <div class="stat-item">
      <div class="stat-value">{{ aggregate_stats.total_sessions }}</div>
      <div class="stat-label">Sessions</div>
    </div>
    <div class="stat-item">
      <div class="stat-value">{{ aggregate_stats.total_duration_min }}</div>
      <div class="stat-label">分鐘</div>
    </div>
    <div class="stat-item">
      <div class="stat-value">{{ aggregate_stats.total_rounds }}</div>
      <div class="stat-label">回合</div>
    </div>
    <div class="stat-item">
      <div class="stat-value">~{{ "{:,}".format(aggregate_stats.total_token_estimate) }}</div>
      <div class="stat-label">Token（粗估）</div>
    </div>
  </div>
  <div class="tool-bar">
    {% for tool, count in aggregate_stats.tool_use_total.items() %}
    <span class="tool-badge">{{ tool }} <span class="tool-count">×{{ count }}</span></span>
    {% endfor %}
  </div>
</div>

{# Individual Sessions #}
<h2 style="color: var(--accent); margin: 16px 0 8px;">各 Session</h2>

{% for session in sessions %}
<details>
  <summary>{{ session.topic }} — {{ session.time_range.duration_min }}min / {{ session.stats.rounds }} 回合</summary>
  <div class="details-content">
    <div class="session-meta">
      {{ session.project }} · {{ session.model }} · {{ session.time_range.start[:10] }}
    </div>
    {% if session.summary %}
    <strong>完成項目：</strong>
    <ul class="summary-list">
      {% for item in session.summary.completions %}
      <li>{{ item }}</li>
      {% endfor %}
    </ul>
    {% endif %}
    <div class="tool-bar" style="margin-top: 8px;">
      {% for tool, count in session.stats.tool_use.items() %}
      <span class="tool-badge">{{ tool }} <span class="tool-count">×{{ count }}</span></span>
      {% endfor %}
    </div>
  </div>
</details>
{% endfor %}

<p style="text-align:center; color:#8b949e; font-size:0.75em; margin-top:24px;">
  Generated by ccs-dashboard · {{ range.since }} ~ {{ range.until }}
</p>

</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add templates/review-weekly.html
git commit -m "feat(review): add weekly report HTML template"
```

---

## Step 5: PDF Export

### Task 5.1: weasyprint Integration

**Files:**
- Modify: `ccs-review-render.py`
- Modify: `ccs-review.sh`
- Modify: `install.sh`

- [ ] **Step 1: Install weasyprint**

Run: `pip3 install --user weasyprint`

- [ ] **Step 2: Add PDF export to ccs-review-render.py**

Add to `ccs-review-render.py` after the `main()` function, replacing it with:

```python
def main():
    script_dir = Path(__file__).parent
    template_dir = script_dir / "templates"

    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        autoescape=True,
    )

    data = json.load(sys.stdin)

    weekly = "--weekly" in sys.argv
    pdf_mode = "--pdf" in sys.argv
    template_name = "review-weekly.html" if weekly else "review.html"
    template = env.get_template(template_name)

    html = template.render(**data)

    if pdf_mode:
        try:
            from weasyprint import HTML
        except ImportError:
            print("Error: weasyprint not installed. Run: pip3 install weasyprint", file=sys.stderr)
            sys.exit(1)
        # Write PDF to stdout (binary)
        pdf_bytes = HTML(string=html).write_pdf()
        sys.stdout.buffer.write(pdf_bytes)
    else:
        print(html)
```

- [ ] **Step 3: Add --format pdf to ccs-review CLI**

In `ccs-review.sh`, in the `ccs-review()` function's case statement for format, add:

```bash
    pdf)
      local outfile
      local slug topic_slug date_slug
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
```

Also add PDF support to `_ccs_review_weekly`:

```bash
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
```

- [ ] **Step 4: Add print CSS to templates**

In both `templates/review.html` and `templates/review-weekly.html`, add inside `<style>`:

```css
  @media print {
    details { display: block; }
    details > summary { display: none; }
    .details-content { border: none; padding: 0; }
    .bubble-text.collapsed { max-height: none; overflow: visible; }
    .bubble-text.collapsed::after { display: none; }
    .expand-btn { display: none; }
    body { max-width: 100%; padding: 0; background: white; color: black; }
    .card { border-color: #ddd; background: #f8f8f8; }
    .stat-value { color: #1a7f37; }
  }
```

- [ ] **Step 5: Add weasyprint check to install.sh**

In `install.sh` `check_deps()`, add:

```bash
  # weasyprint (for ccs-review --format pdf)
  if python3 -c "import weasyprint" 2>/dev/null; then
    ok "weasyprint $(python3 -c 'import weasyprint; print(weasyprint.__version__)')"
  else
    warn "weasyprint not found — optional, for ccs-review --format pdf"
    warn "  Install: pip3 install --user weasyprint"
  fi
```

- [ ] **Step 6: Manual test**

```bash
source ccs-dashboard.sh
ccs-review --format pdf -o ./reports/
```
Open PDF, verify:
- All sections expanded (no collapsed content)
- Print-friendly colors
- Readable layout

- [ ] **Step 7: Commit**

```bash
git add ccs-review-render.py ccs-review.sh templates/review.html templates/review-weekly.html install.sh
git commit -m "feat(review): add PDF export via weasyprint"
```

---

## Final: Integration + Cleanup

### Task F.1: Full Integration Test

- [ ] **Step 1: Run full test suite**

Run: `bash tests/run-all.sh`
Expected: All tests pass

- [ ] **Step 2: Test all output formats on a real session**

```bash
source ccs-dashboard.sh
ccs-review --format json | jq . | head -20
ccs-review --format md | head -30
ccs-review --format html -o ./tmp/
ccs-review --format pdf -o ./tmp/
```

- [ ] **Step 3: Test weekly mode**

```bash
ccs-review --since 2026-03-24 --until 2026-03-31 --format md
ccs-review --since 2026-03-24 --until 2026-03-31 --format html -o ./tmp/
```

- [ ] **Step 4: Update help text in ccs-review**

Ensure `ccs-review --help` documents all flags including `--format pdf`.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "docs(review): update help text and finalize integration"
```
