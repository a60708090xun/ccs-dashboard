#!/usr/bin/env bash
# tests/test-gemini-robust.sh — Robust Gemini parsing tests
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh

setup_test_dir "gemini-robust"

echo "=== _ccs_build_pairs_index: multi-part user content ==="
G_MULTI="$TEST_DIR/gemini-multi.json"
cat > "$G_MULTI" <<'JSON'
{
  "messages": [
    {
      "type": "user",
      "content": [
        {"text": "Part 1"},
        {"text": "Part 2"}
      ],
      "timestamp": "2026-04-14T10:00:00Z"
    },
    {
      "type": "assistant",
      "content": [{"type": "text", "text": "Hi"}],
      "timestamp": "2026-04-14T10:01:00Z"
    }
  ]
}
JSON

result=$(_ccs_build_pairs_index "$G_MULTI")
# Should be exactly one line for the user message
line_count=$(echo "$result" | grep -c $'\t' || echo 0)
assert_eq "G_MULTI: exactly one index line" "1" "$line_count"
assert_contains "G_MULTI: parts joined" "$result" "Part 1 Part 2"

echo ""
echo "=== _ccs_get_pair: Robust role/type and content format ==="
G_ROBUST="$TEST_DIR/gemini-robust.json"
cat > "$G_ROBUST" <<'JSON'
{
  "messages": [
    {
      "role": "user",
      "content": "String content",
      "timestamp": "2026-04-14T10:00:00Z"
    },
    {
      "role": "model",
      "content": "Model response string",
      "timestamp": "2026-04-14T10:01:00Z"
    },
    {
      "type": "user",
      "content": [{"text": "Array content"}],
      "timestamp": "2026-04-14T10:02:00Z"
    },
    {
      "type": "assistant",
      "toolCalls": [
        {"name": "read_file", "args": {"file_path": "bar.txt"}}
      ],
      "timestamp": "2026-04-14T10:03:00Z"
    }
  ]
}
JSON

# Pair 1: role: "user", content: "string"
result=$(_ccs_get_pair "$G_ROBUST" 1 | head -1)
assert_eq "G_ROBUST pair 1 user (string)" '{"role":"user","text":"String content"}' "$result"

# Pair 1: role: "model", content: "string"
result=$(_ccs_get_pair "$G_ROBUST" 1 | tail -1)
assert_eq "G_ROBUST pair 1 assistant (string)" '{"role":"assistant","text":"Model response string"}' "$result"

# Pair 2: type: "user", content: array
result=$(_ccs_get_pair "$G_ROBUST" 2 | head -1)
assert_eq "G_ROBUST pair 2 user (array)" '{"role":"user","text":"Array content"}' "$result"

# Pair 2: type: "assistant", toolCalls (not in content)
result=$(_ccs_get_pair "$G_ROBUST" 2 | tail -1)
assert_contains "G_ROBUST pair 2 assistant toolCalls" "$result" "📖 Read bar.txt"

echo ""
echo "=== _ccs_topic_from_jsonl: Gemini toolCall title ==="
G_TOPIC="$TEST_DIR/gemini-topic-tool.json"
cat > "$G_TOPIC" <<'JSON'
{
  "messages": [
    {
      "type": "user",
      "content": [{"text": "Ignored prompt"}],
      "timestamp": "2026-04-14T10:00:00Z"
    },
    {
      "type": "assistant",
      "toolCalls": [
        {"name": "mcp__happy__change_title", "args": {"title": "Correct Title"}}
      ],
      "timestamp": "2026-04-14T10:01:00Z"
    }
  ]
}
JSON

assert_eq "G_TOPIC: toolCall title" \
  "Correct Title" \
  "$(_ccs_topic_from_jsonl "$G_TOPIC")"

test_summary
