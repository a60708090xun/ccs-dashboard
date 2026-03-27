#!/usr/bin/env bash
# tests/test-health.sh — verify _ccs_health_events output
# Run: bash tests/test-health.sh
set -euo pipefail
cd "$(dirname "$0")/.."

source ccs-health.sh

pass=0 fail=0

assert_json_field() {
  local label="$1" json="$2" query="$3" expected="$4"
  local actual
  actual=$(echo "$json" | jq -r "$query")
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s → got "%s", expected "%s"\n' "$label" "$actual" "$expected"
    fail=$((fail + 1))
  fi
}

# ── Build fixture JSONL ──
FIXTURE_DIR="$(pwd)/tmp/test-health"
mkdir -p "$FIXTURE_DIR"
FIXTURE="$FIXTURE_DIR/abc12345-fake-session-id.jsonl"

cat > "$FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"hello world"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hi there!"}]},"timestamp":"2026-03-21T09:01:00Z"}
{"type":"user","message":{"content":"read some files"},"timestamp":"2026-03-21T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/main.sh"}},{"type":"tool_use","name":"Read","input":{"file_path":"/src/main.sh"}},{"type":"tool_use","name":"Read","input":{"file_path":"/src/util.sh"}}]},"timestamp":"2026-03-21T09:03:00Z"}
{"type":"user","message":{"content":"meta info"},"isMeta":true,"timestamp":"2026-03-21T09:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/main.sh"}},{"type":"tool_use","name":"Grep","input":{"pattern":"TODO"}},{"type":"tool_use","name":"Grep","input":{"pattern":"TODO"}}]},"timestamp":"2026-03-21T09:05:00Z"}
{"type":"user","message":{"content":"one more question"},"timestamp":"2026-03-21T09:10:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Sure!"},{"type":"tool_use","name":"Grep","input":{"pattern":"FIXME"}}]},"timestamp":"2026-03-21T09:11:00Z"}
JSONL

echo "=== _ccs_health_events tests ==="

result=$(_ccs_health_events "$FIXTURE")

# session_id: first 8 chars of filename
assert_json_field "session_id" "$result" '.session_id' "abc12345"

# first_ts / last_ts
assert_json_field "first_ts" "$result" '.first_ts' "2026-03-21T09:00:00Z"
assert_json_field "last_ts" "$result" '.last_ts' "2026-03-21T09:11:00Z"

# prompt_count: 3 user messages (isMeta excluded)
assert_json_field "prompt_count" "$result" '.prompt_count' "3"

# tool_reads: main.sh read 3x (no edit/compact) → 2 dup × half = 2, ÷2 = 1
# util.sh read 1x → no dup (not in output)
assert_json_field "tool_reads main.sh" "$result" '.tool_reads["/src/main.sh"]' "1"
assert_json_field "tool_reads count" "$result" '.tool_reads | length' "1"

# tool_greps: TODO 2x (no compact) → 1 dup × half = 1, ÷2 = 0 (not in output)
# FIXME 1x → no dup (not in output)
assert_json_field "tool_greps count" "$result" '.tool_greps | length' "0"

# ── Smart dup: Read-Edit-Read exclusion ──
echo ""
echo "=== Smart dup: Read-Edit-Read exclusion ==="
RER_FIXTURE="$FIXTURE_DIR/rer00001-read-edit-read.jsonl"
cat > "$RER_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"refactor"},"timestamp":"2026-03-21T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/app.sh"}}]},"timestamp":"2026-03-21T10:01:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/src/app.sh","old_string":"x","new_string":"y"}}]},"timestamp":"2026-03-21T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/app.sh"}}]},"timestamp":"2026-03-21T10:03:00Z"}
JSONL

rer_result=$(_ccs_health_events "$RER_FIXTURE")
assert_json_field "rer tool_reads count" "$rer_result" '.tool_reads | length' "0"

# ── Smart dup: different offset exclusion ──
echo ""
echo "=== Smart dup: different offset ==="
OFF_FIXTURE="$FIXTURE_DIR/off00001-offset.jsonl"
cat > "$OFF_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"read sections"},"timestamp":"2026-03-21T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/big.sh","offset":0,"limit":50}}]},"timestamp":"2026-03-21T10:01:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/big.sh","offset":100,"limit":50}}]},"timestamp":"2026-03-21T10:02:00Z"}
JSONL

off_result=$(_ccs_health_events "$OFF_FIXTURE")
assert_json_field "offset tool_reads count" "$off_result" '.tool_reads | length' "0"

# ── Smart dup: post-compaction full weight ──
echo ""
echo "=== Smart dup: post-compaction ==="
CMP_FIXTURE="$FIXTURE_DIR/cmp00001-compact.jsonl"
cat > "$CMP_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"work"},"timestamp":"2026-03-21T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/core.sh"}}]},"timestamp":"2026-03-21T10:01:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/core.sh"}}]},"timestamp":"2026-03-21T10:03:00Z"}
JSONL

cmp_result=$(_ccs_health_events "$CMP_FIXTURE")
# 1 post-compaction dup × 2 = 2, ÷2 = 1
assert_json_field "compact tool_reads" "$cmp_result" '.tool_reads["/src/core.sh"]' "1"

# ── Smart dup: no-compaction half weight ──
echo ""
echo "=== Smart dup: no-compaction half weight ==="
HALF_FIXTURE="$FIXTURE_DIR/half0001-half.jsonl"
cat > "$HALF_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"work"},"timestamp":"2026-03-21T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/lib.sh"}}]},"timestamp":"2026-03-21T10:01:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/lib.sh"}}]},"timestamp":"2026-03-21T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/src/lib.sh"}}]},"timestamp":"2026-03-21T10:03:00Z"}
JSONL

half_result=$(_ccs_health_events "$HALF_FIXTURE")
# 3 reads, 2 dups × 1 (half) = 2, ÷2 = 1
assert_json_field "half tool_reads" "$half_result" '.tool_reads["/src/lib.sh"]' "1"

# ── Edge case: empty JSONL ──
echo ""
echo "=== Edge case: empty JSONL ==="
EMPTY_FIXTURE="$FIXTURE_DIR/deadbeef-empty.jsonl"
: > "$EMPTY_FIXTURE"

empty_result=$(_ccs_health_events "$EMPTY_FIXTURE")
assert_json_field "empty session_id" "$empty_result" '.session_id' "deadbeef"
assert_json_field "empty prompt_count" "$empty_result" '.prompt_count' "0"
assert_json_field "empty first_ts" "$empty_result" '.first_ts' "null"
assert_json_field "empty last_ts" "$empty_result" '.last_ts' "null"
assert_json_field "empty tool_reads" "$empty_result" '.tool_reads | length' "0"
assert_json_field "empty tool_greps" "$empty_result" '.tool_greps | length' "0"

# ── Edge case: no tool_use, no timestamp ──
echo ""
echo "=== Edge case: no tool_use ==="
NOTOOL_FIXTURE="$FIXTURE_DIR/cafebabe-notool.jsonl"
cat > "$NOTOOL_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"just chatting"},"timestamp":"2026-03-21T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"OK"}]},"timestamp":"2026-03-21T10:01:00Z"}
JSONL

notool_result=$(_ccs_health_events "$NOTOOL_FIXTURE")
assert_json_field "notool prompt_count" "$notool_result" '.prompt_count' "1"
assert_json_field "notool tool_reads" "$notool_result" '.tool_reads | length' "0"
assert_json_field "notool tool_greps" "$notool_result" '.tool_greps | length' "0"

# ══════════════════════════════════════
# _ccs_health_score tests
# ══════════════════════════════════════

echo ""
echo "=== _ccs_health_score: Case 1 — all green ==="
score_green=$(cat <<'JSON' | _ccs_health_score
{
  "session_id": "green001",
  "first_ts": "2026-03-21T09:00:00Z",
  "last_ts": "2026-03-21T09:30:00Z",
  "prompt_count": 5,
  "tool_reads": {"/a": 2, "/b": 1},
  "tool_greps": {"pat": 1}
}
JSON
)
assert_json_field "green overall" "$score_green" '.overall' "green"
assert_json_field "green dup_tool level" "$score_green" '.indicators.dup_tool.level' "green"
assert_json_field "green dup_tool value" "$score_green" '.indicators.dup_tool.value' "2"
assert_json_field "green duration level" "$score_green" '.indicators.duration.level' "green"
assert_json_field "green duration value" "$score_green" '.indicators.duration.value' "30"
assert_json_field "green rounds level" "$score_green" '.indicators.rounds.level' "green"
assert_json_field "green rounds value" "$score_green" '.indicators.rounds.value' "5"

echo ""
echo "=== _ccs_health_score: Case 2 — yellow (duration) ==="
score_yellow=$(cat <<'JSON' | _ccs_health_score
{
  "session_id": "yell0001",
  "first_ts": "2026-03-20T09:00:00Z",
  "last_ts": "2026-03-22T09:00:00Z",
  "prompt_count": 10,
  "tool_reads": {"/a": 1},
  "tool_greps": {}
}
JSON
)
assert_json_field "yellow overall" "$score_yellow" '.overall' "yellow"
assert_json_field "yellow duration level" "$score_yellow" '.indicators.duration.level' "yellow"
assert_json_field "yellow duration value" "$score_yellow" '.indicators.duration.value' "2880"
assert_json_field "yellow dup_tool level" "$score_yellow" '.indicators.dup_tool.level' "green"
assert_json_field "yellow rounds level" "$score_yellow" '.indicators.rounds.level' "green"

echo ""
echo "=== _ccs_health_score: Case 3 — red (dup_tool) ==="
score_red=$(cat <<'JSON' | _ccs_health_score
{
  "session_id": "redd0001",
  "first_ts": "2026-03-21T09:00:00Z",
  "last_ts": "2026-03-21T09:10:00Z",
  "prompt_count": 3,
  "tool_reads": {"/a": 6, "/b": 2},
  "tool_greps": {"x": 1}
}
JSON
)
assert_json_field "red overall" "$score_red" '.overall' "red"
assert_json_field "red dup_tool level" "$score_red" '.indicators.dup_tool.level' "red"
assert_json_field "red dup_tool value" "$score_red" '.indicators.dup_tool.value' "6"
assert_json_field "red duration level" "$score_red" '.indicators.duration.level' "green"
assert_json_field "red rounds level" "$score_red" '.indicators.rounds.level' "green"

echo ""
echo "=== _ccs_health_score: Case 4 — composite (overall=red) ==="
score_comp=$(cat <<'JSON' | _ccs_health_score
{
  "session_id": "comp0001",
  "first_ts": "2026-03-21T06:00:00Z",
  "last_ts": "2026-03-21T12:00:00Z",
  "prompt_count": 45,
  "tool_reads": {"/a": 6, "/b": 2},
  "tool_greps": {"x": 3}
}
JSON
)
assert_json_field "comp overall" "$score_comp" '.overall' "red"
assert_json_field "comp duration level" "$score_comp" '.indicators.duration.level' "green"
assert_json_field "comp duration value" "$score_comp" '.indicators.duration.value' "360"
assert_json_field "comp dup_tool level" "$score_comp" '.indicators.dup_tool.level' "red"
assert_json_field "comp dup_tool value" "$score_comp" '.indicators.dup_tool.value' "6"
assert_json_field "comp rounds level" "$score_comp" '.indicators.rounds.level' "yellow"
assert_json_field "comp rounds value" "$score_comp" '.indicators.rounds.value' "45"

echo ""
echo "=== _ccs_health_score: Case 5 — null timestamps ==="
score_null=$(cat <<'JSON' | _ccs_health_score
{
  "session_id": "null0001",
  "first_ts": null,
  "last_ts": null,
  "prompt_count": 0,
  "tool_reads": {},
  "tool_greps": {}
}
JSON
)
assert_json_field "null overall" "$score_null" '.overall' "green"
assert_json_field "null duration level" "$score_null" '.indicators.duration.level' "green"
assert_json_field "null duration value" "$score_null" '.indicators.duration.value' "0"
assert_json_field "null dup_tool value" "$score_null" '.indicators.dup_tool.value' "0"
assert_json_field "null rounds value" "$score_null" '.indicators.rounds.value' "0"

# ══════════════════════════════════════
# _ccs_health_badge tests
# ══════════════════════════════════════

echo ""
echo "=== _ccs_health_badge tests ==="

# Fixture: green session (short, few prompts, no dup)
GREEN_FIXTURE="$FIXTURE_DIR/aabbccdd-green.jsonl"
cat > "$GREEN_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"hello"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp":"2026-03-21T09:05:00Z"}
JSONL

# Fixture: yellow session (post-compaction dups → dup_val=3, hits yellow)
YELLOW_FIXTURE="$FIXTURE_DIR/eeff0011-yellow.jsonl"
cat > "$YELLOW_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"start"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T09:01:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T09:03:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T09:05:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:06:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T09:07:00Z"}
JSONL

# Fixture: red session (post-compaction dups → dup_val=5, hits red)
RED_FIXTURE="$FIXTURE_DIR/22334455-red.jsonl"
cat > "$RED_FIXTURE" <<'JSONL'
{"type":"user","message":{"content":"read"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]},"timestamp":"2026-03-21T09:01:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]},"timestamp":"2026-03-21T09:03:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]},"timestamp":"2026-03-21T09:05:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:06:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]},"timestamp":"2026-03-21T09:07:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:08:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]},"timestamp":"2026-03-21T09:09:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T09:10:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}]},"timestamp":"2026-03-21T09:11:00Z"}
JSONL

assert_badge() {
  local label="$1" fixture="$2" expected_symbol="$3"
  local actual
  # Strip ANSI color codes for comparison
  actual=$(_ccs_health_badge "$fixture" | sed 's/\x1b\[[0-9;]*m//g')
  if [ "$actual" = "$expected_symbol" ]; then
    printf '  PASS: %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s → got "%s", expected "%s"\n' \
      "$label" "$actual" "$expected_symbol"
    fail=$((fail + 1))
  fi
}

assert_badge_md() {
  local label="$1" fixture="$2" expected_emoji="$3"
  local actual
  actual=$(_ccs_health_badge_md "$fixture")
  if [ "$actual" = "$expected_emoji" ]; then
    printf '  PASS: %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s → got "%s", expected "%s"\n' \
      "$label" "$actual" "$expected_emoji"
    fail=$((fail + 1))
  fi
}

assert_badge "green badge symbol" "$GREEN_FIXTURE" "●"
assert_badge "yellow badge symbol" "$YELLOW_FIXTURE" "◐"
assert_badge "red badge symbol" "$RED_FIXTURE" "○"

echo ""
echo "=== _ccs_health_badge_md tests ==="

assert_badge_md "green badge md" "$GREEN_FIXTURE" "🟢"
assert_badge_md "yellow badge md" "$YELLOW_FIXTURE" "🟡"
assert_badge_md "red badge md" "$RED_FIXTURE" "🔴"

# ══════════════════════════════════════
# ccs-health command tests
# ══════════════════════════════════════

echo ""
echo "=== ccs-health command tests ==="

# Source ccs-core.sh for helpers (cwd is project root via line 5)
source ccs-core.sh

# Build mock project directory structure
MOCK_PROJECTS="$FIXTURE_DIR/mock-projects"
mkdir -p "$MOCK_PROJECTS/-pool2-testuser-project-alpha"
mkdir -p "$MOCK_PROJECTS/-pool2-testuser-project-beta"

# Green session in project-alpha
ALPHA_GREEN="$MOCK_PROJECTS/-pool2-testuser-project-alpha/aaaa1111-0000-0000-0000-000000000001.jsonl"
cat > "$ALPHA_GREEN" <<'JSONL'
{"type":"user","message":{"content":"hello alpha"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hi!"}]},"timestamp":"2026-03-21T09:05:00Z"}
JSONL

# Red session in project-beta (post-compaction dups → dup_val=5)
BETA_RED="$MOCK_PROJECTS/-pool2-testuser-project-beta/bbbb2222-0000-0000-0000-000000000002.jsonl"
cat > "$BETA_RED" <<'JSONL'
{"type":"user","message":{"content":"read lots"},"timestamp":"2026-03-21T08:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T08:01:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T08:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T08:03:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T08:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T08:05:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T08:06:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T08:07:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T08:08:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T08:09:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T08:10:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]},"timestamp":"2026-03-21T08:11:00Z"}
JSONL

# Yellow session in project-alpha (post-compaction dups → dup_val=3)
ALPHA_YELLOW="$MOCK_PROJECTS/-pool2-testuser-project-alpha/cccc3333-0000-0000-0000-000000000003.jsonl"
cat > "$ALPHA_YELLOW" <<'JSONL'
{"type":"user","message":{"content":"long session"},"timestamp":"2026-03-21T07:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/y"}}]},"timestamp":"2026-03-21T07:01:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T07:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/y"}}]},"timestamp":"2026-03-21T07:03:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T07:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/y"}}]},"timestamp":"2026-03-21T07:05:00Z"}
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-03-21T07:06:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/y"}}]},"timestamp":"2026-03-21T07:07:00Z"}
JSONL

# Touch files to make them appear recent
touch "$ALPHA_GREEN" "$BETA_RED" "$ALPHA_YELLOW"

# Override _ccs_is_archived to never archive in tests
_ccs_is_archived() { return 1; }

# Test 1: --json outputs valid JSON array
echo ""
echo "--- Test: ccs-health --json valid JSON array ---"
json_out=$(CCS_PROJECTS_DIR="$MOCK_PROJECTS" ccs-health --json 2>/dev/null)
json_type=$(echo "$json_out" | jq -r 'type' 2>/dev/null)
if [ "$json_type" = "array" ]; then
  printf '  PASS: --json outputs JSON array\n'
  pass=$((pass + 1))
else
  printf '  FAIL: --json type → got "%s", expected "array"\n' "$json_type"
  fail=$((fail + 1))
fi

json_len=$(echo "$json_out" | jq 'length')
if [ "$json_len" = "3" ]; then
  printf '  PASS: --json has 3 sessions\n'
  pass=$((pass + 1))
else
  printf '  FAIL: --json length → got "%s", expected "3"\n' "$json_len"
  fail=$((fail + 1))
fi

# Test 2: prefix filter returns single session
echo ""
echo "--- Test: ccs-health <prefix> --json single session ---"
prefix_out=$(CCS_PROJECTS_DIR="$MOCK_PROJECTS" ccs-health aaaa1111 --json 2>/dev/null)
prefix_len=$(echo "$prefix_out" | jq 'length')
if [ "$prefix_len" = "1" ]; then
  printf '  PASS: prefix filter returns 1 session\n'
  pass=$((pass + 1))
else
  printf '  FAIL: prefix filter length → got "%s", expected "1"\n' "$prefix_len"
  fail=$((fail + 1))
fi

prefix_sid=$(echo "$prefix_out" | jq -r '.[0].session_id')
if [ "$prefix_sid" = "aaaa1111" ]; then
  printf '  PASS: prefix filter correct session_id\n'
  pass=$((pass + 1))
else
  printf '  FAIL: prefix filter sid → got "%s", expected "aaaa1111"\n' "$prefix_sid"
  fail=$((fail + 1))
fi

# Test 3: --md output contains header
echo ""
echo "--- Test: ccs-health --md header ---"
md_out=$(CCS_PROJECTS_DIR="$MOCK_PROJECTS" ccs-health --md 2>/dev/null)
if echo "$md_out" | grep -q "## Session Health Report"; then
  printf '  PASS: --md contains header\n'
  pass=$((pass + 1))
else
  printf '  FAIL: --md missing "## Session Health Report"\n'
  fail=$((fail + 1))
fi

# Test 4: sorting — red before yellow before green in JSON
echo ""
echo "--- Test: sorting (red first, green last) ---"
first_overall=$(echo "$json_out" | jq -r '.[0].overall')
last_overall=$(echo "$json_out" | jq -r '.[-1].overall')
if [ "$first_overall" = "red" ]; then
  printf '  PASS: first session is red\n'
  pass=$((pass + 1))
else
  printf '  FAIL: first overall → got "%s", expected "red"\n' "$first_overall"
  fail=$((fail + 1))
fi
if [ "$last_overall" = "green" ]; then
  printf '  PASS: last session is green\n'
  pass=$((pass + 1))
else
  printf '  FAIL: last overall → got "%s", expected "green"\n' "$last_overall"
  fail=$((fail + 1))
fi

# Test 5: --json includes project and topic fields
echo ""
echo "--- Test: JSON fields (project, topic) ---"
first_project=$(echo "$json_out" | jq -r '.[0].project')
if [ -n "$first_project" ] && [ "$first_project" != "null" ]; then
  printf '  PASS: project field present\n'
  pass=$((pass + 1))
else
  printf '  FAIL: project field missing or null\n'
  fail=$((fail + 1))
fi

first_topic=$(echo "$json_out" | jq -r '.[0].topic')
if [ -n "$first_topic" ] && [ "$first_topic" != "null" ]; then
  printf '  PASS: topic field present\n'
  pass=$((pass + 1))
else
  printf '  FAIL: topic field missing or null\n'
  fail=$((fail + 1))
fi

# Test 6: no active sessions
echo ""
echo "--- Test: empty projects dir ---"
EMPTY_PROJECTS="$FIXTURE_DIR/empty-projects"
mkdir -p "$EMPTY_PROJECTS"
empty_json=$(CCS_PROJECTS_DIR="$EMPTY_PROJECTS" ccs-health --json 2>/dev/null)
empty_len=$(echo "$empty_json" | jq 'length')
if [ "$empty_len" = "0" ]; then
  printf '  PASS: empty dir returns empty array\n'
  pass=$((pass + 1))
else
  printf '  FAIL: empty dir length → got "%s", expected "0"\n' "$empty_len"
  fail=$((fail + 1))
fi

# Test 7: archived session is excluded
echo ""
echo "--- Test: archived session excluded ---"
# Create a session with a last-prompt marker and no
# subsequent assistant (archived per _ccs_is_archived)
ARCHIVED_SESSION="$MOCK_PROJECTS/-pool2-testuser-project-alpha/dddd4444-0000-0000-0000-000000000004.jsonl"
cat > "$ARCHIVED_SESSION" <<'JSONL'
{"type":"user","message":{"content":"start"},"timestamp":"2026-03-21T06:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-21T06:01:00Z"}
{"type":"last-prompt","message":{"content":"start"},"timestamp":"2026-03-21T06:01:00Z"}
JSONL

# Restore real _ccs_is_archived for this test
unset -f _ccs_is_archived
source ccs-core.sh

archived_json=$(CCS_PROJECTS_DIR="$MOCK_PROJECTS" \
  ccs-health --json 2>/dev/null)
archived_len=$(echo "$archived_json" | jq 'length')
# The archived session should be excluded, leaving 3 sessions
if [ "$archived_len" = "3" ]; then
  printf '  PASS: archived session excluded (3 active)\n'
  pass=$((pass + 1))
else
  printf '  FAIL: expected 3 sessions, got "%s"\n' \
    "$archived_len"
  fail=$((fail + 1))
fi
# Verify dddd4444 is not in results
archived_ids=$(echo "$archived_json" \
  | jq -r '.[].session_id')
if echo "$archived_ids" | grep -q "dddd4444"; then
  printf '  FAIL: archived session dddd4444 found in results\n'
  fail=$((fail + 1))
else
  printf '  PASS: archived session dddd4444 not in results\n'
  pass=$((pass + 1))
fi

# Re-override _ccs_is_archived for subsequent tests
_ccs_is_archived() { return 1; }

# Test 8: terminal output contains legend
echo ""
echo "--- Test: terminal output legend ---"
term_out=$(CCS_PROJECTS_DIR="$MOCK_PROJECTS" ccs-health 2>/dev/null)
# Strip ANSI
term_plain=$(echo "$term_out" | sed 's/\x1b\[[0-9;]*m//g')
if echo "$term_plain" | grep -q "Legend"; then
  printf '  PASS: terminal output has Legend\n'
  pass=$((pass + 1))
else
  printf '  FAIL: terminal output missing Legend\n'
  fail=$((fail + 1))
fi

# ══════════════════════════════════════
# Crash filter test (GH#28 fix #3)
# ══════════════════════════════════════

echo ""
echo "--- Test: crashed session excluded from health ---"

# Add a "crashed" session to project-alpha
CRASHED_SESSION="$MOCK_PROJECTS/-pool2-testuser-project-alpha/ffff6666-0000-0000-0000-000000000006.jsonl"
cat > "$CRASHED_SESSION" <<'JSONL'
{"type":"user","message":{"content":"crashed session"},"timestamp":"2026-03-21T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"working..."}]},"timestamp":"2026-03-21T09:01:00Z"}
JSONL
touch "$CRASHED_SESSION"

# Mock _ccs_detect_crash to mark this session as crashed
_ccs_detect_crash() {
  local -n _out=$1
  _out["ffff6666-0000-0000-0000-000000000006"]="high:hung"
}

crash_json=$(CCS_PROJECTS_DIR="$MOCK_PROJECTS" ccs-health --json 2>/dev/null)
crash_ids=$(echo "$crash_json" | jq -r '.[].session_id')
if echo "$crash_ids" | grep -q "ffff6666"; then
  printf '  FAIL: crashed session ffff6666 found in health results\n'
  fail=$((fail + 1))
else
  printf '  PASS: crashed session ffff6666 excluded from health\n'
  pass=$((pass + 1))
fi

# Verify non-crashed sessions still present
crash_len=$(echo "$crash_json" | jq 'length')
if [ "$crash_len" -ge 1 ]; then
  printf '  PASS: non-crashed sessions still in results (%s)\n' "$crash_len"
  pass=$((pass + 1))
else
  printf '  FAIL: no sessions in results (expected >= 1)\n'
  fail=$((fail + 1))
fi

# Restore real _ccs_detect_crash
unset -f _ccs_detect_crash
source ccs-core.sh

# Clean up crashed fixture
rm -f "$CRASHED_SESSION"

# ══════════════════════════════════════
# Millisecond timestamp test
# ══════════════════════════════════════

echo ""
echo "--- Test: timestamps with milliseconds ---"
score_ms=$(cat <<'JSON' | _ccs_health_score
{
  "session_id": "ms000001",
  "first_ts": "2026-03-20T09:00:00.123Z",
  "last_ts": "2026-03-22T09:00:00.456Z",
  "prompt_count": 5,
  "tool_reads": {},
  "tool_greps": {}
}
JSON
)
assert_json_field "ms duration level" "$score_ms" '.indicators.duration.level' "yellow"
assert_json_field "ms duration value" "$score_ms" '.indicators.duration.value' "2880"
assert_json_field "ms overall" "$score_ms" '.overall' "yellow"

# Cleanup
rm -rf "$FIXTURE_DIR"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
