#!/usr/bin/env bash
# tests/test-overview.sh — _ccs_overview_session_data last-exchange extraction
# Run: bash tests/test-overview.sh
#
# Regression for issue #50: new Claude Code transcripts store user message
# content as an array of content blocks (text / tool_result), not a string.
# last_exchange.user must extract the real prompt text from array content,
# while ignoring pure tool_result user messages.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tests/fixture-helper.sh"
source "$ROOT/ccs-core.sh"
source "$ROOT/ccs-overview.sh"

setup_test_dir "overview"

echo "=== _ccs_overview_session_data: array-content user messages (issue #50) ==="

# Session with array-content user prompts + a trailing tool_result-only
# user message (the modern Claude Code transcript format).
ARR="$TEST_DIR/arr-session.jsonl"
cat > "$ARR" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"first array question"}]},"timestamp":"2026-06-01T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"answer 1"}]},"timestamp":"2026-06-01T09:01:00Z"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"deploy the fix"}]},"timestamp":"2026-06-01T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-06-01T09:03:00Z"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_x","type":"tool_result","content":"Todos modified"}]},"timestamp":"2026-06-01T09:04:00Z"}
JSONL

out_arr=$(_ccs_overview_session_data "$ARR")
last_user_arr=$(echo "$out_arr" | jq -r '.last_exchange.user')

# The last REAL prompt is "deploy the fix"; the trailing tool_result-only
# user message must NOT be treated as the last prompt.
assert_eq "array-content: last real prompt extracted" \
  "deploy the fix" "$last_user_arr"
assert_not_contains "array-content: tool_result not surfaced as prompt" \
  "$last_user_arr" "Todos modified"

echo ""
echo "=== _ccs_overview_session_data: legacy string-content (regression) ==="

# Old-format session: user content is a plain string.
STR="$TEST_DIR/str-session.jsonl"
cat > "$STR" <<'JSONL'
{"type":"user","message":{"role":"user","content":"old string question"},"timestamp":"2026-06-01T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"old answer"}]},"timestamp":"2026-06-01T09:01:00Z"}
JSONL

out_str=$(_ccs_overview_session_data "$STR")
last_user_str=$(echo "$out_str" | jq -r '.last_exchange.user')
assert_eq "string-content: last prompt still extracted (regression)" \
  "old string question" "$last_user_str"

echo ""
echo "=== _ccs_overview_session_data: truncated final line (crash tail) ==="

# Crash-interrupted sessions often have a half-written final line. The
# valid prior records (incl. the last real prompt) must still be read.
TRUNC="$TEST_DIR/trunc-session.jsonl"
{
  echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"the real last prompt"}]},"timestamp":"2026-06-01T09:00:00Z"}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working on it"}]},"timestamp":"2026-06-01T09:01:00Z"}'
  printf '%s' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"par'
} > "$TRUNC"

out_trunc=$(_ccs_overview_session_data "$TRUNC")
last_user_trunc=$(echo "$out_trunc" | jq -r '.last_exchange.user')
assert_eq "truncated-tail: recovers last valid prompt" \
  "the real last prompt" "$last_user_trunc"

echo ""
echo "=== _ccs_overview_session_data: interrupted turn + tool_use skip ==="

# Last prompt followed by a tool_use-only assistant, a tool_result, then a
# text assistant: the surfaced assistant text must skip the empty tool_use
# turn. Then a final prompt with no assistant (interrupted) -> assistant "".
MIX="$TEST_DIR/mix-session.jsonl"
cat > "$MIX" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"run the build"}]},"timestamp":"2026-06-01T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"make"}}]},"timestamp":"2026-06-01T09:01:00Z"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"built"}]},"timestamp":"2026-06-01T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"build succeeded"}]},"timestamp":"2026-06-01T09:03:00Z"}
JSONL

out_mix=$(_ccs_overview_session_data "$MIX")
assert_eq "tool_use-skip: surfaces text assistant not empty tool_use turn" \
  "build succeeded" "$(echo "$out_mix" | jq -r '.last_exchange.assistant')"
assert_eq "tool_use-skip: last prompt is the real text prompt" \
  "run the build" "$(echo "$out_mix" | jq -r '.last_exchange.user')"

# Interrupted: session ends on a real prompt with no assistant after.
INTR="$TEST_DIR/intr-session.jsonl"
cat > "$INTR" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"first"}]},"timestamp":"2026-06-01T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"reply"}]},"timestamp":"2026-06-01T09:01:00Z"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"interrupted prompt"}]},"timestamp":"2026-06-01T09:02:00Z"}
JSONL

out_intr=$(_ccs_overview_session_data "$INTR")
assert_eq "interrupted: last prompt extracted" \
  "interrupted prompt" "$(echo "$out_intr" | jq -r '.last_exchange.user')"
assert_eq "interrupted: assistant empty (no turn after prompt)" \
  "" "$(echo "$out_intr" | jq -r '.last_exchange.assistant')"

test_summary
