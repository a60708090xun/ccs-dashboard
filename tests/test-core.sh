#!/usr/bin/env bash
# tests/test-core.sh — ccs-core.sh function tests
# Run: bash tests/test-core.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh

setup_test_dir "core"

echo "=== _ccs_topic_from_jsonl: tag stripping ==="

# Case A: XML tag wrapping content
A="$TEST_DIR/tag-wrap.jsonl"
cat > "$A" <<'JSONL'
{"type":"user","message":{"content":"<command-message>hello world</command-message>"},"timestamp":"2026-03-21T09:00:00Z"}
JSONL
assert_eq "A: strip wrapping tags" \
  "hello world " \
  "$(_ccs_topic_from_jsonl "$A")"

# Case B: <system-reminder> — skipped by select filter
B="$TEST_DIR/system-reminder.jsonl"
cat > "$B" <<'JSONL'
{"type":"user","message":{"content":"<system-reminder>internal data</system-reminder>"},"timestamp":"2026-03-21T09:00:00Z"}
JSONL
assert_eq "B: system-reminder skipped" \
  "-" \
  "$(_ccs_topic_from_jsonl "$B")"

# Case C: normal message, no tags
C="$TEST_DIR/normal.jsonl"
cat > "$C" <<'JSONL'
{"type":"user","message":{"content":"fix the bug"},"timestamp":"2026-03-21T09:00:00Z"}
JSONL
assert_eq "C: normal message preserved" \
  "fix the bug " \
  "$(_ccs_topic_from_jsonl "$C")"

# Case D: change_title takes priority
D="$TEST_DIR/change-title.jsonl"
cat > "$D" <<'JSONL'
{"type":"user","message":{"content":"do stuff"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__happy__change_title","input":{"title":"My Session Title"}}]},"timestamp":"2026-03-21T09:01:00Z"}
JSONL
assert_eq "D: change_title priority" \
  "My Session Title" \
  "$(_ccs_topic_from_jsonl "$D")"

# Case E: first message has tag, second normal
E="$TEST_DIR/mixed.jsonl"
cat > "$E" <<'JSONL'
{"type":"user","message":{"content":"<command-message>tagged content</command-message>"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"user","message":{"content":"normal second message"},"timestamp":"2026-03-21T09:01:00Z"}
JSONL
assert_eq "E: first msg tag stripped" \
  "tagged content " \
  "$(_ccs_topic_from_jsonl "$E")"

# Case F: malformed tag (no closing)
F="$TEST_DIR/malformed.jsonl"
cat > "$F" <<'JSONL'
{"type":"user","message":{"content":"<command-message>no close tag"},"timestamp":"2026-03-21T09:00:00Z"}
JSONL
assert_eq "F: malformed tag stripped" \
  "no close tag " \
  "$(_ccs_topic_from_jsonl "$F")"

# Case G: isMeta skipped
G="$TEST_DIR/meta.jsonl"
cat > "$G" <<'JSONL'
{"type":"user","message":{"content":"meta msg"},"isMeta":true,"timestamp":"2026-03-21T09:00:00Z"}
{"type":"user","message":{"content":"real msg"},"timestamp":"2026-03-21T09:01:00Z"}
JSONL
assert_eq "G: isMeta skipped, real msg used" \
  "real msg " \
  "$(_ccs_topic_from_jsonl "$G")"

test_summary
