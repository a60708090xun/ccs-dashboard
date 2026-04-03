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
assert_eq "C: duration" "30" "$(echo "$stats_json" | jq -r '.time_range.duration_min')"
assert_eq "C: tool Read" "1" "$(echo "$stats_json" | jq -r '.tool_use.Read')"
assert_eq "C: has char_count" "true" "$(echo "$stats_json" | jq 'has("char_count")')"
assert_eq "C: has token_estimate" "true" "$(echo "$stats_json" | jq 'has("token_estimate")')"

echo "=== _ccs_review_json: full JSON output ==="

D="$TEST_DIR/review-session.jsonl"
cat > "$D" <<'JSONL'
{"type":"user","message":{"content":"add dark mode"},"timestamp":"2026-04-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/style.css"}},{"type":"text","text":"I see the current styles."}]},"timestamp":"2026-04-01T10:01:00Z"}
{"type":"user","message":{"content":"go ahead"},"timestamp":"2026-04-01T10:05:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/style.css","old_string":"bg: white","new_string":"bg: var(--bg)"}},{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Add dark mode toggle","status":"completed"},{"content":"Test on mobile","status":"pending"}]}},{"type":"text","text":"Done."}]},"timestamp":"2026-04-01T10:20:00Z"}
JSONL

review_json=$(_ccs_review_json "$D")
assert_eq "D: has session_id" "true" "$(echo "$review_json" | jq 'has("session_id")')"
assert_eq "D: has stats" "true" "$(echo "$review_json" | jq 'has("stats")')"
assert_eq "D: has conversation" "true" "$(echo "$review_json" | jq 'has("conversation")')"
assert_eq "D: conversation length" "2" "$(echo "$review_json" | jq '.conversation | length')"
assert_eq "D: todos length" "2" "$(echo "$review_json" | jq '.todos | length')"
assert_eq "D: summary is null" "null" "$(echo "$review_json" | jq -r '.summary')"
assert_contains "D: recent_files has Read" "$(echo "$review_json" | jq -r '.recent_files[]')" "R /style.css"

echo "=== _ccs_review_md: markdown output ==="

# Reuse fixture D from above
md_output=$(_ccs_review_json "$D" | _ccs_review_md)
assert_contains "D-md: has title" "$md_output" "# Session Review"
assert_contains "D-md: has stats" "$md_output" "回合"
assert_contains "D-md: has conversation" "$md_output" "add dark mode"
assert_contains "D-md: has todos" "$md_output" "Add dark mode toggle"

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

echo "=== HTML rendering: end-to-end ==="

if python3 -c "import jinja2" 2>/dev/null; then
  _RENDER_PY="$(pwd)/ccs-review-render.py"
  html_output=$(_ccs_review_json "$D" | python3 "$_RENDER_PY")
  assert_contains "HTML: has doctype" "$html_output" "<!DOCTYPE html>"
  assert_contains "HTML: has topic" "$html_output" "add dark mode"
  assert_contains "HTML: has stats" "$html_output" "回合"
  assert_contains "HTML: has chat bubble" "$html_output" "bubble-user"
else
  echo "  SKIP: jinja2 not installed"
fi

echo "=== _ccs_review_weekly_collect: date range ==="

WEEKLY_DIR="$TEST_DIR/weekly-projects/test-proj"
mkdir -p "$WEEKLY_DIR"

W1="$WEEKLY_DIR/sess-in-range.jsonl"
cat > "$W1" <<'JSONL'
{"type":"user","message":{"content":"task A"},"timestamp":"2026-03-25T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done A."}]},"timestamp":"2026-03-25T10:30:00Z"}
JSONL
touch -d "2026-03-25 10:30:00" "$W1"

W2="$WEEKLY_DIR/sess-too-old.jsonl"
cat > "$W2" <<'JSONL'
{"type":"user","message":{"content":"task B"},"timestamp":"2026-03-20T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done B."}]},"timestamp":"2026-03-20T10:30:00Z"}
JSONL
touch -d "2026-03-20 10:30:00" "$W2"

collected=$(CCS_PROJECTS_DIR="$TEST_DIR/weekly-projects" _ccs_review_weekly_collect "2026-03-24" "2026-03-31")
assert_contains "weekly: includes in-range" "$collected" "sess-in-range"
assert_not_contains "weekly: excludes too-old" "$collected" "sess-too-old"

echo "=== _ccs_review_weekly_json: aggregate ==="

weekly_json=$(CCS_PROJECTS_DIR="$TEST_DIR/weekly-projects" _ccs_review_weekly_json "2026-03-24" "2026-03-31")
assert_eq "weekly: has range" "2026-03-24" "$(echo "$weekly_json" | jq -r '.range.since')"
assert_eq "weekly: session count" "1" "$(echo "$weekly_json" | jq '.aggregate_stats.total_sessions')"
assert_eq "weekly: has sessions array" "true" "$(echo "$weekly_json" | jq 'has("sessions")')"

test_summary
