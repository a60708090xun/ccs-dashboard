#!/usr/bin/env bash
# tests/test-failure-triage.sh — verify _ccs_failure_run_checks output
# Run: bash tests/test-failure-triage.sh
set -euo pipefail
cd "$(dirname "$0")/.."

source ccs-core.sh
source ccs-failure-triage.sh

pass=0
fail=0

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    printf '  PASS: %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s → output did not contain: %s\n' "$label" "$needle"
    fail=$((fail + 1))
  fi
}

# ── Fixture directory ──
FIXTURE_DIR="$(pwd)/tmp/test-failure-triage"
mkdir -p "$FIXTURE_DIR"

# Env overrides for deterministic behaviour
export CCS_FAILURE_LONG_TURN_MS=600000
export CCS_FAILURE_MULTI_SEG_MIN=2

# ══════════════════════════════════════
# Test 1: clean_transcript
# 3 real user prompts, 3 text-only assistant responses, no suspicious content
# Expected: "No confabulation signals detected"
# ══════════════════════════════════════
echo "=== Test 1: clean_transcript ==="

CLEAN="$FIXTURE_DIR/clean_transcript.jsonl"
cat > "$CLEAN" <<'JSONL'
{"type":"user","message":{"content":"Hello, how are you?"},"timestamp":"2026-06-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"I am doing well, thank you for asking."}]},"timestamp":"2026-06-01T10:00:05Z"}
{"type":"user","message":{"content":"Can you explain recursion?"},"timestamp":"2026-06-01T10:01:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Recursion is when a function calls itself."}]},"timestamp":"2026-06-01T10:01:10Z"}
{"type":"user","message":{"content":"What is a binary tree?"},"timestamp":"2026-06-01T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"A binary tree is a tree data structure where each node has at most two children."}]},"timestamp":"2026-06-01T10:02:08Z"}
JSONL

result1=$(_ccs_failure_run_checks "$CLEAN")
assert_contains "clean: no confabulation signals" "$result1" "No confabulation signals detected"

# ══════════════════════════════════════
# Test 2: user_prompt_count
# 3 real user prompts + 1 tool_result user record + 1 <local-command-caveat> record
# Expected: "Total: **3**"
# ══════════════════════════════════════
echo ""
echo "=== Test 2: user_prompt_count ==="

COUNT="$FIXTURE_DIR/user_prompt_count.jsonl"
cat > "$COUNT" <<'JSONL'
{"type":"user","message":{"content":"First real question"},"timestamp":"2026-06-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Answer one."}]},"timestamp":"2026-06-01T10:00:05Z"}
{"type":"user","message":{"content":"Second real question"},"timestamp":"2026-06-01T10:01:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Answer two."}]},"timestamp":"2026-06-01T10:01:05Z"}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"file contents here"}]},"timestamp":"2026-06-01T10:01:10Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Got it."}]},"timestamp":"2026-06-01T10:01:15Z"}
{"type":"user","message":{"content":"<local-command-caveat>This is injected caveat</local-command-caveat>"},"timestamp":"2026-06-01T10:01:20Z"}
{"type":"user","message":{"content":"Third real question"},"timestamp":"2026-06-01T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Answer three."}]},"timestamp":"2026-06-01T10:02:05Z"}
JSONL

result2=$(_ccs_failure_run_checks "$COUNT")
assert_contains "prompt_count: Total is 3" "$result2" "Total: **3**"

# ══════════════════════════════════════
# Test 3: multi_segment_turn
# Two consecutive assistant records with text after a single user prompt
# Expected: output contains "multi-text-segment"
# ══════════════════════════════════════
echo ""
echo "=== Test 3: multi_segment_turn ==="

MULTI="$FIXTURE_DIR/multi_segment_turn.jsonl"
cat > "$MULTI" <<'JSONL'
{"type":"user","message":{"content":"Please do a complex task"},"timestamp":"2026-06-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Starting the first part of my response here."}]},"timestamp":"2026-06-01T10:00:10Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Here is the second part of my response, continuing the same turn."}]},"timestamp":"2026-06-01T10:00:20Z"}
JSONL

result3=$(_ccs_failure_run_checks "$MULTI")
assert_contains "multi_segment: detected multi-text-segment" "$result3" "multi-text-segment"

# ══════════════════════════════════════
# Test 4: phrasing_red_flag
# Assistant text contains "讓你久等抱歉"
# Expected: output contains "自我糾正" or "red flag" or "self-correction"
# ══════════════════════════════════════
echo ""
echo "=== Test 4: phrasing_red_flag ==="

PHRASING="$FIXTURE_DIR/phrasing_red_flag.jsonl"
cat > "$PHRASING" <<'JSONL'
{"type":"user","message":{"content":"What happened?"},"timestamp":"2026-06-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"讓你久等抱歉，我剛才在處理一個複雜的問題。"}]},"timestamp":"2026-06-01T10:00:30Z"}
JSONL

result4=$(_ccs_failure_run_checks "$PHRASING")
# Check 4 section header is "Self-correction / apology phrasing red flags"
# The pattern label contains "zh:讓你久等/讓你等了" and the summary says "self-correction phrasing detected"
if echo "$result4" | grep -qF "self-correction phrasing detected" || \
   echo "$result4" | grep -qiF "red flag" || \
   echo "$result4" | grep -qF "自我糾正" || \
   echo "$result4" | grep -qF "讓你久等/讓你等了"; then
  printf '  PASS: phrasing_red_flag: check 4 hit detected\n'
  pass=$((pass + 1))
else
  printf '  FAIL: phrasing_red_flag → expected self-correction/red-flag signal in output\n'
  fail=$((fail + 1))
fi

# ══════════════════════════════════════
# Test 5: narrative_divergence
# Assistant text contains "abc1234" (7-char hex), no tool_result with that string
# Expected: output contains "abc1234" in divergence section
# ══════════════════════════════════════
echo ""
echo "=== Test 5: narrative_divergence ==="

DIVERGE="$FIXTURE_DIR/narrative_divergence.jsonl"
cat > "$DIVERGE" <<'JSONL'
{"type":"user","message":{"content":"What was the last commit?"},"timestamp":"2026-06-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"The last commit was abc1234 which added the new feature."}]},"timestamp":"2026-06-01T10:00:10Z"}
JSONL

result5=$(_ccs_failure_run_checks "$DIVERGE")
assert_contains "narrative_divergence: abc1234 appears in divergence section" "$result5" "abc1234"

# ── Cleanup ──
rm -rf "$FIXTURE_DIR"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
