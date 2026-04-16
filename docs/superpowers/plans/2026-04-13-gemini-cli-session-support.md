# Gemini CLI Session Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure `ccs-dashboard` commands provide full support for Gemini CLI sessions (`.json` format) alongside existing Claude Code sessions (`.jsonl` format).

**Architecture:** Abstract the session reading logic in `ccs-core.sh` to handle both `.jsonl` (Claude) and `.json` (Gemini) formats transparently by detecting the provider via file extension. Then, update downstream `jq` pipelines to normalize Gemini's JSON array format into a JSONL stream before processing, or adjust the queries to handle both. Finally, replace hardcoded glob patterns to find both file types.

**Tech Stack:** Bash, jq

---

## Phase 1: Core Infrastructure (CRITICAL)

### Task 1: Add `_ccs_get_provider` & Update `_ccs_topic_from_jsonl`

**Files:**
- Modify: `ccs-core.sh`
- Modify: `tests/test-core.sh`

- [ ] **Step 1: Add `_ccs_get_provider` to `ccs-core.sh`**

Add this helper right above `_ccs_is_archived()`:
```bash
_ccs_get_provider() {
  local f="$1"
  if [[ "$f" == *.json ]]; then
    echo "gemini"
  else
    echo "claude"
  fi
}
```

- [ ] **Step 2: Refactor `_ccs_topic_from_jsonl` to support Gemini**

Replace `_ccs_topic_from_jsonl()` in `ccs-core.sh` (around line 63):
```bash
_ccs_topic_from_jsonl() {
  local f="$1"
  local topic=""
  local provider=$(_ccs_get_provider "$f")
  
  if grep -q "change_title" "$f" 2>/dev/null; then
    # Both formats can be filtered with standard jq if we unpack Gemini arrays
    if [ "$provider" = "gemini" ]; then
      topic=$(jq -r '.[] | select(.type == "tool_use" and .name == "mcp__happy__change_title") | .input.title' "$f" 2>/dev/null | tail -1)
    else
      topic=$(grep "change_title" "$f" 2>/dev/null | jq -r '
        .message.content[]? |
        select(.type == "tool_use" and .name == "mcp__happy__change_title") |
        .input.title' 2>/dev/null | tail -1)
    fi
  fi
  if [ -z "$topic" ]; then
    # Find first real user message
    if [ "$provider" = "gemini" ]; then
      topic=$(jq -r '
        .[] | select(.type == "user" and (.message.content | type == "string")
          and ((.isMeta // false) == false)
          and (.message.content | test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
          and (.message.content | test("^\\s*$") | not))
        | .message.content | gsub("<[^>]+>"; "") | gsub("^\\s+|\\s+$"; "")
      ' "$f" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c1-120)
    else
      topic=$(jq -r '
        select(.type == "user" and (.message.content | type == "string")
          and ((.isMeta // false) == false)
          and (.message.content | test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
          and (.message.content | test("^\\s*$") | not))
        | .message.content | gsub("<[^>]+>"; "") | gsub("^\\s+|\\s+$"; "")
      ' "$f" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c1-120)
    fi
  fi
  [ -z "$topic" ] && topic="-"
  echo "$topic"
}
```

- [ ] **Step 3: Update `tests/test-core.sh` to add Gemini mock**

Append to `tests/test-core.sh`:
```bash
H="$TEST_DIR/gemini-topic.json"
cat > "$H" <<'JSON'
[{"type":"user","message":{"content":"gemini topic"},"timestamp":"2026-04-13T09:00:00Z"},{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp":"2026-04-13T09:01:00Z"}]
JSON
assert_eq "gemini basic topic" "gemini topic" "$(_ccs_topic_from_jsonl "$H")"
```

- [ ] **Step 4: Run test and Commit**

Run: `bash tests/test-core.sh`
Expected: PASS
Command: `git add ccs-core.sh tests/test-core.sh && git commit -m "feat(core): add _ccs_get_provider and update _ccs_topic_from_jsonl for Gemini support"`

### Task 2: Update `_ccs_is_archived` & `_ccs_detect_crash`

**Files:**
- Modify: `ccs-core.sh`

- [ ] **Step 1: Modify `_ccs_is_archived`**

At the very top of `_ccs_is_archived()` in `ccs-core.sh`, add:
```bash
  local f="$1"
  if [ "$(_ccs_get_provider "$f")" = "gemini" ]; then
    return 1 # Gemini doesn't use standard archive markers yet
  fi
```

- [ ] **Step 2: Modify `_ccs_detect_crash`**

In `_ccs_detect_crash()`, after getting `mtime` for Claude (`local mtime=$(stat -c %Y "$f")`), add logic to read Gemini's `lastUpdated` or fallback to `mtime`:
```bash
      # Use jq to extract last timestamp if possible, fallback to mtime
      if [[ "$f" == *.json ]]; then
         local last_ts=$(jq -r '.[-1].timestamp // empty' "$f" 2>/dev/null)
         if [ -n "$last_ts" ]; then
           mtime=$(date -d "$last_ts" +%s 2>/dev/null || stat -c %Y "$f")
         else
           mtime=$(stat -c %Y "$f")
         fi
      else
         mtime=$(stat -c %Y "$f")
      fi
```

- [ ] **Step 3: Commit**

Command: `git add ccs-core.sh && git commit -m "feat(core): support Gemini in _ccs_is_archived and _ccs_detect_crash"`

---

## Phase 2: Core Commands (HIGH)

### Task 3: Normalizing `_ccs_overview_session_data`

**Files:**
- Modify: `ccs-overview.sh`

- [ ] **Step 1: Refactor `_ccs_overview_session_data()`**

Modify `_ccs_overview_session_data()` in `ccs-overview.sh` to unpack Gemini JSON arrays before running the `jq` pipeline. Change the first `jq -c` call to:

```bash
  local provider=$(_ccs_get_provider "$jsonl")
  local jq_filter
  if [ "$provider" = "gemini" ]; then
    jq_filter='.[] | select(.type == "user" and (.message.content | type == "string"))'
  else
    jq_filter='select(.type == "user" and (.message.content | type == "string"))'
  fi

  local last_raw_idx
  last_raw_idx=$(jq -c "$jq_filter" "$jsonl" 2>/dev/null \
```

Do the same for `todos_json`:
```bash
  local todos_filter
  if [ "$provider" = "gemini" ]; then
    todos_filter='.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "TodoWrite") | [.input.todos[]? | {content, status}]'
  else
    todos_filter='select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "TodoWrite") | [.input.todos[]? | {content, status}]'
  fi
  todos_json=$(jq -c "$todos_filter" "$jsonl" 2>/dev/null | tail -1)
```

- [ ] **Step 2: Commit**

Command: `git add ccs-overview.sh && git commit -m "feat(overview): normalize Gemini JSON for _ccs_overview_session_data"`

### Task 4: Normalizing `_ccs_health_events`

**Files:**
- Modify: `ccs-health.sh`

- [ ] **Step 1: Update `_ccs_health_events`**

In `ccs-health.sh`, `_ccs_health_events()` currently uses `jq -s 'reduce .[] as $line...'`. For a Gemini `.json` file, which is already an array, `jq -s` wraps it in another array `[[...]]`. We need to unwrap it or conditionally pipe.

Change the jq invocation:
```bash
  local provider=$(_ccs_get_provider "$f")
  local pipe_cmd="cat"
  if [ "$provider" = "gemini" ]; then
    pipe_cmd="jq -c .[]"
  fi

  eval "$pipe_cmd '$f'" 2>/dev/null | jq -s --arg sid "$sid" '
    reduce .[] as $line (
```

- [ ] **Step 2: Run test and Commit**

Run: `bash tests/test-health.sh`
Expected: PASS
Command: `git add ccs-health.sh && git commit -m "feat(health): support Gemini JSON in _ccs_health_events"`

### Task 5: Normalizing `_ccs_session_stats`

**Files:**
- Modify: `ccs-review.sh`

- [ ] **Step 1: Update `_ccs_session_stats`**

In `ccs-review.sh`, apply the same `pipe_cmd` trick for both `rounds` and `char_count`.
```bash
  local provider=$(_ccs_get_provider "$jsonl")
  local pipe_cmd="cat"
  if [ "$provider" = "gemini" ]; then
    pipe_cmd="jq -c .[]"
  fi

  local rounds
  rounds=$(eval "$pipe_cmd '$jsonl'" 2>/dev/null | jq -s '[.[] | select(.type == "user" and (.message.content | type == "string"))] | length' 2>/dev/null)

  local first_ts last_ts
  first_ts=$(eval "$pipe_cmd '$jsonl'" 2>/dev/null | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | head -1)
  last_ts=$(eval "$pipe_cmd '$jsonl'" 2>/dev/null | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | tail -1)
```

Apply `eval "$pipe_cmd '$jsonl'" 2>/dev/null | jq -s '...` for `char_count` as well.
Update `_ccs_tool_use_stats()` in `ccs-review.sh` with the same `pipe_cmd` normalization.

- [ ] **Step 2: Run test and Commit**

Run: `bash tests/test-review.sh`
Expected: PASS
Command: `git add ccs-review.sh && git commit -m "feat(review): support Gemini JSON in _ccs_session_stats"`

---

## Phase 3 & 4: Handoff/Resume & Glob Replacement

### Task 6: Hardcoded `find ... *.jsonl` Globs

**Files:**
- Modify: `ccs-ops.sh`, `ccs-core.sh`, `ccs-health.sh`

- [ ] **Step 1: Replace Globs**

Run a systematic replacement for `find` commands looking for `.jsonl` files.
Instead of `-name "*.jsonl"`, use `\( -name "*.jsonl" -o -name "*.json" \)`

Example in `ccs-core.sh` (`_ccs_resolve_jsonl()`):
```bash
find "$projects_dir" -maxdepth 2 \( -name "${prefix}*.jsonl" -o -name "${prefix}*.json" \) ! -path "*/subagents/*" 2>/dev/null | head -1
```

Apply this in `_ccs_collect_sessions` (`ccs-ops.sh`), `_ccs_health_events` (if it loops), and any other `find` queries.

- [ ] **Step 2: Commit**

Command: `git add ccs-core.sh ccs-ops.sh && git commit -m "feat(core): replace hardcoded .jsonl globs with dual support"`

### Task 7: Handoff & Resume

**Files:**
- Modify: `ccs-dashboard.sh`
- Modify: `ccs-handoff.sh`

- [ ] **Step 1: Update `ccs-resume-prompt`**

In `ccs-dashboard.sh`, `ccs-resume-prompt` uses `claude --resume`. 
Add a check for provider:
```bash
      "ccs-resume-prompt")
        file=$(_ccs_resolve_jsonl "$2")
        [ -z "$file" ] && return 1
        local provider=$(_ccs_get_provider "$file")
        local sid
        if [ "$provider" = "gemini" ]; then
          sid=$(basename "$file" .json | cut -c1-8)
          echo "gemini --session $sid"
        else
          sid=$(basename "$file" .jsonl | cut -c1-8)
          echo "claude --resume $sid"
        fi
        ;;
```

- [ ] **Step 2: Commit**

Command: `git add ccs-dashboard.sh && git commit -m "feat(dashboard): support Gemini in ccs-resume-prompt"`