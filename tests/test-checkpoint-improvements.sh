#!/usr/bin/env bash
# Test checkpoint improvements (GH#13+14)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/ccs-core.sh"
source "$PROJECT_DIR/ccs-dashboard.sh"

PASS=0 FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$(( FAIL + 1 ))
  fi
}

# === Test: Task: sessions are filtered ===
echo "=== Task: session filtering ==="
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT
MOCK_JSONL="$TEST_DIR/test.jsonl"

cat > "$MOCK_JSONL" <<'JSONL'
{"type":"user","message":{"content":"Task: echo hello"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}
JSONL

topic=$(_ccs_topic_from_jsonl "$MOCK_JSONL")
# _ccs_topic_from_jsonl appends a trailing space via tr '\n' ' '
assert_eq "Task: topic detected" "Task: echo hello " "$topic"
if [[ "$topic" == Task:* ]]; then
  assert_eq "Task: pattern matches" "yes" "yes"
else
  assert_eq "Task: pattern matches" "yes" "no"
fi

# === Test: Blocked two-stage — naturally ended → done ===
echo ""
echo "=== Blocked two-stage: naturally ended ==="
cat > "$MOCK_JSONL" <<'JSONL'
{"type":"user","message":{"content":"幫我確認 happy 狀態"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Happy daemon 正常運作中。"}]}}
JSONL

last_type=$(jq -s '[.[] | select(.type == "assistant" or .type == "user")] | last | .type // ""' "$MOCK_JSONL" 2>/dev/null)
assert_eq "last_type is assistant" '"assistant"' "$last_type"

todos_json=$(jq -s -c '[.[] | select(.type == "assistant") | .message.content[]? |
  select(.type == "tool_use" and .name == "TodoWrite") |
  .input.todos] | last // [] | [.[]? | select(.status != "completed") | {status, content}]' "$MOCK_JSONL" 2>/dev/null)
[ -z "$todos_json" ] || [ "$todos_json" = "null" ] && todos_json="[]"
todo_count=$(echo "$todos_json" | jq 'length')
assert_eq "no pending todos" "0" "$todo_count"

is_blocked=false
age_min=180
if (( age_min > 120 )); then
  if [ "$last_type" = '"assistant"' ] && (( todo_count == 0 )); then
    is_blocked=false
  else
    is_blocked=true
  fi
fi
assert_eq "naturally ended → not blocked" "false" "$is_blocked"

# === Test: Blocked two-stage — truly blocked ===
echo ""
echo "=== Blocked two-stage: truly blocked ==="
cat > "$MOCK_JSONL" <<'JSONL'
{"type":"user","message":{"content":"幫我修這個 bug"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Fix bug","status":"in_progress","activeForm":"Fixing bug"}]}}]}}
{"type":"user","message":{"content":"等一下，我需要確認上游的 API"}}
JSONL

last_type=$(jq -s '[.[] | select(.type == "assistant" or .type == "user")] | last | .type // ""' "$MOCK_JSONL" 2>/dev/null)
assert_eq "last_type is user" '"user"' "$last_type"

todos_json=$(jq -s -c '[.[] | select(.type == "assistant") | .message.content[]? |
  select(.type == "tool_use" and .name == "TodoWrite") |
  .input.todos] | last // [] | [.[]? | select(.status != "completed") | {status, content}]' "$MOCK_JSONL" 2>/dev/null)
[ -z "$todos_json" ] || [ "$todos_json" = "null" ] && todos_json="[]"
todo_count=$(echo "$todos_json" | jq 'length')
assert_eq "has pending todos" "1" "$todo_count"

is_blocked=false
age_min=180
if (( age_min > 120 )); then
  if [ "$last_type" = '"assistant"' ] && (( todo_count == 0 )); then
    is_blocked=false
  else
    is_blocked=true
  fi
fi
assert_eq "truly blocked → blocked" "true" "$is_blocked"

# === Test: Time format — same day vs cross-day ===
echo ""
echo "=== Time format ==="
today_ymd=$(date +%Y%m%d)
same_day_epoch=$(date -d "today 09:30" +%s)
mtime_ymd=$(date -d "@$same_day_epoch" +%Y%m%d)
if [ "$mtime_ymd" = "$today_ymd" ]; then
  la=$(date -d "@$same_day_epoch" '+%H:%M')
else
  la=$(date -d "@$same_day_epoch" '+%m/%d %H:%M')
fi
assert_eq "same day → HH:MM" "09:30" "$la"

cross_day_epoch=$(date -d "2 days ago 14:00" +%s)
mtime_ymd=$(date -d "@$cross_day_epoch" +%Y%m%d)
if [ "$mtime_ymd" = "$today_ymd" ]; then
  la=$(date -d "@$cross_day_epoch" '+%H:%M')
else
  la=$(date -d "@$cross_day_epoch" '+%m/%d %H:%M')
fi
expected_cross=$(date -d "2 days ago 14:00" '+%m/%d %H:%M')
assert_eq "cross day → MM/DD HH:MM" "$expected_cross" "$la"

# === Test: Done collapse output ===
echo ""
echo "=== Done collapse ==="
test_json='{"done":[{"project":"aaa","topic":"t1","session":"s1"},{"project":"aaa","topic":"t2","session":"s2"},{"project":"bbb","topic":"t3","session":"s3"}],"in_progress":[],"blocked":[],"since":"03/21 09:00","now":"03/21 15:00","summary":{"total":3,"done":3,"in_progress":0,"blocked":0}}'
done_out=$(echo "$test_json" | jq -r '[.done[] | {project}] | group_by(.project) | map("- **" + .[0].project + "** — " + (length|tostring) + " session" + (if length > 1 then "s" else "" end)) | .[]')
assert_eq "done collapse: aaa 2 sessions" "- **aaa** — 2 sessions" "$(echo "$done_out" | head -1)"
assert_eq "done collapse: bbb 1 session" "- **bbb** — 1 session" "$(echo "$done_out" | tail -1)"

# === Test: Grouping logic ===
echo ""
echo "=== Grouping logic ==="
test_json2='{"done":[],"in_progress":[{"project":"proj-a","topic":"task1","session":"s1","last_active":"14:30","todos":[],"todo_count":0},{"project":"proj-a","topic":"task2","session":"s2","last_active":"13:20","todos":[],"todo_count":0},{"project":"proj-b","topic":"task3","session":"s3","last_active":"12:10","todos":[],"todo_count":0}],"blocked":[],"since":"03/21 09:00","now":"03/21 15:00","summary":{"total":3,"done":0,"in_progress":3,"blocked":0}}'
group_out=$(echo "$test_json2" | jq -r '.in_progress | group_by(.project) | .[] | if length >= 2 then "GROUP:" + .[0].project else "FLAT:" + .[0].project end')
assert_eq "proj-a grouped" "GROUP:proj-a" "$(echo "$group_out" | head -1)"
assert_eq "proj-b flat" "FLAT:proj-b" "$(echo "$group_out" | tail -1)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL
