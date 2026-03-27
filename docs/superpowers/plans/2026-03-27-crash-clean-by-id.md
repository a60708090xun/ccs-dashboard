# ccs-crash --clean \<id...\> Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support `ccs-crash --clean <id...>` to archive specific crashed sessions by ID with prefix matching.

**Architecture:** Add a new `_ccs_crash_clean_by_id()` function in `ccs-ops.sh`, modify `ccs-crash()` argument parsing to collect session IDs after `--clean`, and skip confidence filtering when IDs are specified.

**Tech Stack:** Bash (existing project stack)

---

### Task 1: Add `_ccs_crash_clean_by_id()` function

**Files:**
- Modify: `ccs-ops.sh:175-181` (insert after `_ccs_archive_session`)
- Test: `tests/test-crash-clean-by-id.sh` (new)

- [ ] **Step 1: Write the test file**

```bash
#!/usr/bin/env bash
# tests/test-crash-clean-by-id.sh
# Run: bash tests/test-crash-clean-by-id.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tests/fixture-helper.sh"
source "$ROOT/ccs-core.sh"
source "$ROOT/ccs-ops.sh"

setup_test_dir "crash-clean-by-id"

# ── Build mock sessions ──
MOCK_PROJ="$TEST_DIR/projects/-mock-project"
mkdir -p "$MOCK_PROJ"

# Session A: d25fd727-...
SA="$MOCK_PROJ/d25fd727-0000-0000-0000-000000000001.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"

# Session B: d25f1111-...
SB="$MOCK_PROJ/d25f1111-0000-0000-0000-000000000002.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"

# Session C: abcd0000-...
SC="$MOCK_PROJ/abcd0000-0000-0000-0000-000000000003.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"

# Build crash_map and session_files arrays
declare -A crash_map=(
  ["d25fd727-0000-0000-0000-000000000001"]="high:reboot"
  ["d25f1111-0000-0000-0000-000000000002"]="low:idle"
  ["abcd0000-0000-0000-0000-000000000003"]="high:reboot"
)
session_files=("$SA" "$SB" "$SC")
session_projects=(
  "-mock-project"
  "-mock-project"
  "-mock-project"
)

# ── Mock _ccs_topic_from_jsonl ──
_ccs_topic_from_jsonl() { echo "test topic"; }

echo "=== Test 1: exact match — single ID ==="
out=$(_ccs_crash_clean_by_id \
  crash_map session_files session_projects \
  "d25fd727-0000-0000-0000-000000000001")
assert_contains "archived d25fd727" "$out" "d25fd727"
assert_contains "shows checkmark" "$out" "✓"
# Verify file actually archived
last=$(tail -1 "$SA")
assert_eq "last-prompt marker" \
  '{"type":"last-prompt"}' "$last"

echo ""
echo "=== Test 2: prefix match — unique ==="
# Reset session C
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files session_projects \
  "abcd")
assert_contains "archived abcd0000" "$out" "abcd0000"
last=$(tail -1 "$SC")
assert_eq "last-prompt marker" \
  '{"type":"last-prompt"}' "$last"

echo ""
echo "=== Test 3: prefix match — ambiguous ==="
# Reset sessions
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files session_projects \
  "d25f")
assert_contains "ambiguous error" "$out" "ambiguous"
assert_contains "lists match 1" "$out" "d25fd727"
assert_contains "lists match 2" "$out" "d25f1111"
# Verify NOT archived
last_a=$(tail -1 "$SA")
last_b=$(tail -1 "$SB")
assert_not_contains "SA not archived" \
  "$last_a" "last-prompt"
assert_not_contains "SB not archived" \
  "$last_b" "last-prompt"

echo ""
echo "=== Test 4: no match ==="
out=$(_ccs_crash_clean_by_id \
  crash_map session_files session_projects \
  "zzzzz")
assert_contains "not found" "$out" "not found"

echo ""
echo "=== Test 5: multiple IDs ==="
# Reset all
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files session_projects \
  "d25fd727-0000-0000-0000-000000000001" \
  "abcd")
assert_contains "archived d25fd727" "$out" "d25fd727"
assert_contains "archived abcd0000" "$out" "abcd0000"
last_a=$(tail -1 "$SA")
last_c=$(tail -1 "$SC")
assert_eq "SA archived" \
  '{"type":"last-prompt"}' "$last_a"
assert_eq "SC archived" \
  '{"type":"last-prompt"}' "$last_c"

echo ""
echo "=== Test 6: mixed — one valid, one bad ==="
# Reset SA
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files session_projects \
  "d25fd727-0000-0000-0000-000000000001" \
  "zzzzz")
assert_contains "archived d25fd727" "$out" "d25fd727"
assert_contains "zzzzz not found" "$out" "not found"

echo ""
test_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-crash-clean-by-id.sh`
Expected: FAIL — `_ccs_crash_clean_by_id: command not found`

- [ ] **Step 3: Implement `_ccs_crash_clean_by_id`**

Insert after `_ccs_archive_session()` (line 181) in `ccs-ops.sh`:

```bash
# ── ccs-crash: clean by session ID ──
_ccs_crash_clean_by_id() {
  local -n _map=$1 _files=$2 _projects=$3
  shift 3
  local -a ids=("$@")

  local archived=0 not_found=0 ambiguous=0

  for id in "${ids[@]}"; do
    # Find matching session IDs via prefix
    local -a matches=() match_files=() match_projects=()
    local count=${#_files[@]}
    for ((i = 0; i < count; i++)); do
      local f="${_files[$i]}"
      local sid=$(basename "$f" .jsonl)
      [ -n "${_map[$sid]+x}" ] || continue
      if [[ "$sid" == "$id"* ]]; then
        matches+=("$sid")
        match_files+=("$f")
        match_projects+=("${_projects[$i]}")
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

  printf '\n\033[1mDone:\033[0m %d archived' "$archived"
  [ "$not_found" -gt 0 ] && \
    printf ', %d not found' "$not_found"
  [ "$ambiguous" -gt 0 ] && \
    printf ', %d ambiguous' "$ambiguous"
  printf '\n'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-crash-clean-by-id.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-ops.sh \
  tests/test-crash-clean-by-id.sh
git commit -m "feat: add _ccs_crash_clean_by_id \
with prefix match (ref #33)"
```

---

### Task 2: Modify `ccs-crash()` argument parsing and confidence bypass

**Files:**
- Modify: `ccs-ops.sh:252-314` (`ccs-crash()` function)
- Test: `tests/test-crash-clean-by-id.sh` (append)

- [ ] **Step 1: Write integration tests**

Append to `tests/test-crash-clean-by-id.sh` before `test_summary`:

```bash
echo ""
echo "=== Test 7: ccs-crash --clean <id> end-to-end ==="

# Mock _ccs_collect_sessions to use our test data
_ccs_collect_sessions() {
  local show_all=false
  if [ "${1:-}" = "--all" ]; then
    show_all=true; shift
  fi
  local -n _of=$1 _op=$2 _or=$3
  _of=("$SA" "$SB" "$SC")
  _op=("-mock-project" "-mock-project" "-mock-project")
  _or=("mock-row" "mock-row" "mock-row")
}

# Mock _ccs_detect_crash to populate crash_map
_ccs_detect_crash() {
  local -n _cm=$1
  _cm=(
    ["d25fd727-0000-0000-0000-000000000001"]="high:reboot"
    ["d25f1111-0000-0000-0000-000000000002"]="low:idle"
    ["abcd0000-0000-0000-0000-000000000003"]="high:reboot"
  )
}

# Reset sessions
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"

out=$(ccs-crash --clean abcd 2>&1)
assert_contains "e2e archive abcd" "$out" "abcd0000"
assert_contains "e2e checkmark" "$out" "✓"
last=$(tail -1 "$SC")
assert_eq "e2e last-prompt" \
  '{"type":"last-prompt"}' "$last"

echo ""
echo "=== Test 8: low confidence session ==="
echo "=== reachable by --clean <id> ==="

# Reset SB (low confidence)
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"

out=$(ccs-crash --clean d25f1111 2>&1)
assert_contains "low-conf archived" "$out" "d25f1111"
last=$(tail -1 "$SB")
assert_eq "low-conf last-prompt" \
  '{"type":"last-prompt"}' "$last"

echo ""
echo "=== Test 9: --clean without ID ==="
echo "=== falls through to interactive ==="

# Just verify it doesn't crash with our mocks
# (interactive mode reads stdin — we skip it)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-crash-clean-by-id.sh`
Expected: FAIL at Test 7 — `ccs-crash --clean abcd` doesn't recognize ID argument yet

- [ ] **Step 3: Modify `ccs-crash()` argument parsing**

In `ccs-ops.sh`, change the `--clean` case and add `clean-id` mode handling:

Replace in `ccs-crash()`:
```bash
# Old:
      --clean)         mode="clean"; shift ;;
```
With:
```bash
# New:
      --clean)
        mode="clean"; shift
        # Collect session IDs after --clean
        local -a clean_ids=()
        while [ $# -gt 0 ] && \
          [[ "$1" != --* ]]; do
          clean_ids+=("$1"); shift
        done
        [ ${#clean_ids[@]} -gt 0 ] && \
          mode="clean-id"
        ;;
```

Add confidence filter bypass — replace:
```bash
  # Filter low confidence unless --all
  if ! $show_all; then
```
With:
```bash
  # Filter low confidence unless --all
  # or --clean <id> (explicit ID skips filter)
  if ! $show_all && \
    [ "$mode" != "clean-id" ]; then
```

Add `clean-id` case to the `case "$mode"` block:
```bash
    clean-id)
      _ccs_crash_clean_by_id \
        crash_map session_files \
        session_projects "${clean_ids[@]}"
      ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-crash-clean-by-id.sh`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-ops.sh \
  tests/test-crash-clean-by-id.sh
git commit -m "feat: wire --clean <id...> into \
ccs-crash argument parser (ref #33)"
```

---

### Task 3: Update help text

**Files:**
- Modify: `ccs-ops.sh:264-275` (help text in `ccs-crash()`)

- [ ] **Step 1: Write test**

Append to `tests/test-crash-clean-by-id.sh` before `test_summary`:

```bash
echo ""
echo "=== Test 10: help text includes <id> ==="
help_out=$(ccs-crash --help 2>&1)
assert_contains "help shows --clean <id>" \
  "$help_out" "--clean <id...>"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-crash-clean-by-id.sh`
Expected: FAIL at Test 10 — help text doesn't mention `<id...>` yet

- [ ] **Step 3: Update help text**

In `ccs-ops.sh`, replace the help Usage section:

```
Usage:
  ccs-crash                    Markdown output (default)
  ccs-crash --json             JSON output
  ccs-crash --all              Include low confidence
  ccs-crash --clean            Interactive cleanup
  ccs-crash --clean <id...>    Archive specific session(s)
                               by ID (prefix match)
  ccs-crash --clean-all        Archive all crashed sessions
  ccs-crash --reboot-window N  Path 1 window (default: 30)
  ccs-crash --idle-window N    Path 2 window (default: 1440)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-crash-clean-by-id.sh`
Expected: All PASS

- [ ] **Step 5: Run full test suite**

Run: `bash tests/run-all.sh`
Expected: No regressions

- [ ] **Step 6: Commit**

```bash
git add ccs-ops.sh \
  tests/test-crash-clean-by-id.sh
git commit -m "docs: update ccs-crash help text \
for --clean <id...> (ref #33)"
```

---

### Task 4: Register test in runner + final verification

**Files:**
- Modify: `tests/run-all.sh`

- [ ] **Step 1: Add test to runner**

Add `test-crash-clean-by-id.sh` to the test list in `tests/run-all.sh`.

- [ ] **Step 2: Run full suite**

Run: `bash tests/run-all.sh`
Expected: All tests PASS, including new ones

- [ ] **Step 3: Commit**

```bash
git add tests/run-all.sh
git commit -m "test: register crash-clean-by-id \
in test runner (ref #33)"
```
