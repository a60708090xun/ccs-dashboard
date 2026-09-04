#!/usr/bin/env bash
# tests/test-run-cost.sh — ccs-run-cost cross-session run token accounting tests (GH#117)
set -euo pipefail

# Force UTF-8 locale so multibyte strings (e.g. "本報告僅涵蓋可取得 usage 的 provider",
# "usage 不可得") and tables are parsed and asserted consistently regardless of the
# ambient environment locale (preventing character folding/truncation errors under LANG=C).
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh

source ccs-run.sh

setup_test_dir "run-cost"

PROJECTS_DIR="$TEST_DIR/projects/test-proj"
mkdir -p "$PROJECTS_DIR"
export CCS_PROJECTS_DIR="$TEST_DIR/projects"

# Sanity assertion: ensure ccs-run-cost is executable and defined
echo "=== Sanity check: ccs-run-cost executable ==="
sanity_help=$(ccs-run-cost --help 2>&1)
assert_eq "sanity: ccs-run-cost --help exits 0" "0" "$?"
assert_contains "sanity: help text contains Usage: ccs-run-cost" "$sanity_help" "Usage: ccs-run-cost"

# Helper for safe jq evaluation (warns on invalid JSON, returns empty string on empty input)
jq_val() {
  local query="$1"
  local input
  input=$(cat)
  if [ -z "$input" ]; then
    echo ""
    return 0
  fi
  if ! echo "$input" | jq -e . >/dev/null 2>&1; then
    echo "Warning: jq_val received invalid JSON" >&2
    echo ""
    return 0
  fi
  echo "$input" | jq -r "$query"
}

echo "=== Fixture 1 & A7: Single request & Metric independence ==="
F1="$PROJECTS_DIR/sess-1-single.jsonl"
cat > "$F1" <<'JSONL'
{"type":"assistant","requestId":"req-1","timestamp":"2026-09-04T10:00:00Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40,"output_tokens_details":{"thinking_tokens":5}}}}
JSONL

out_f1=$(ccs-run-cost sess-1-single --format json 2>/dev/null || true)
assert_eq "A7: fixture 1 usage_available == true" "true" "$(echo "$out_f1" | jq_val '.sessions[0].usage_available')"
assert_eq "A7: fixture 1 requests == 1" "1" "$(echo "$out_f1" | jq_val '.sessions[0].totals.requests')"
assert_eq "A7: fixture 1 rows == 1" "1" "$(echo "$out_f1" | jq_val '.sessions[0].totals.rows')"
assert_eq "A7: fixture 1 input == 10" "10" "$(echo "$out_f1" | jq_val '.sessions[0].totals.input')"
assert_eq "A7: fixture 1 output == 20" "20" "$(echo "$out_f1" | jq_val '.sessions[0].totals.output')"
assert_eq "A7: fixture 1 billable == 30" "30" "$(echo "$out_f1" | jq_val '.sessions[0].totals.billable')"
assert_eq "A7: fixture 1 cache_read == 30" "30" "$(echo "$out_f1" | jq_val '.sessions[0].totals.cache_read')"
assert_eq "A7: fixture 1 cache_creation == 40" "40" "$(echo "$out_f1" | jq_val '.sessions[0].totals.cache_creation')"
assert_eq "A7: fixture 1 thinking == 5" "5" "$(echo "$out_f1" | jq_val '.sessions[0].totals.thinking')"

echo "=== Fixture 2 & A1: Main transcript deduplication ==="
F2="$PROJECTS_DIR/sess-2-main.jsonl"
cat > "$F2" <<'JSONL'
{"type":"assistant","requestId":"req-main-1","timestamp":"2026-09-04T10:00:00Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":100,"output_tokens":300,"cache_read_input_tokens":500,"cache_creation_input_tokens":50,"output_tokens_details":{"thinking_tokens":120}}}}
{"type":"assistant","requestId":"req-main-1","timestamp":"2026-09-04T10:00:01Z","apiBlockIndex":1,"message":{"usage":{"input_tokens":100,"output_tokens":300,"cache_read_input_tokens":500,"cache_creation_input_tokens":50,"output_tokens_details":{"thinking_tokens":120}}}}
{"type":"assistant","requestId":"req-main-1","timestamp":"2026-09-04T10:00:02Z","apiBlockIndex":2,"message":{"usage":{"input_tokens":100,"output_tokens":300,"cache_read_input_tokens":500,"cache_creation_input_tokens":50,"output_tokens_details":{"thinking_tokens":120}}}}
JSONL

out_f2=$(ccs-run-cost sess-2-main --format json 2>/dev/null || true)
assert_eq "A1: main shape rows == 3" "3" "$(echo "$out_f2" | jq_val '.sessions[0].totals.rows')"
assert_eq "A1: main shape requests == 1" "1" "$(echo "$out_f2" | jq_val '.sessions[0].totals.requests')"
assert_eq "A1: main shape output == 300" "300" "$(echo "$out_f2" | jq_val '.sessions[0].totals.output')"
assert_eq "A1: main shape input == 100" "100" "$(echo "$out_f2" | jq_val '.sessions[0].totals.input')"
assert_eq "A1: main shape billable == 400" "400" "$(echo "$out_f2" | jq_val '.sessions[0].totals.billable')"
assert_eq "A1: main shape cache_read == 500" "500" "$(echo "$out_f2" | jq_val '.sessions[0].totals.cache_read')"
assert_eq "A1: main shape cache_creation == 50" "50" "$(echo "$out_f2" | jq_val '.sessions[0].totals.cache_creation')"
assert_eq "A1: main shape thinking == 120" "120" "$(echo "$out_f2" | jq_val '.sessions[0].totals.thinking')"

echo "=== Fixture 3 & A2: Subagent streaming deduplication ==="
F3="$PROJECTS_DIR/sess-3-subagent-shape.jsonl"
cat > "$F3" <<'JSONL'
{"type":"assistant","requestId":"req-sub-1","timestamp":"2026-09-04T10:00:00Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":50,"output_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens_details":{"thinking_tokens":0}}}}
{"type":"assistant","requestId":"req-sub-1","timestamp":"2026-09-04T10:00:01Z","apiBlockIndex":1,"message":{"usage":{"input_tokens":50,"output_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens_details":{"thinking_tokens":0}}}}
{"type":"assistant","requestId":"req-sub-1","timestamp":"2026-09-04T10:00:02Z","apiBlockIndex":2,"message":{"usage":{"input_tokens":50,"output_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens_details":{"thinking_tokens":0}}}}
{"type":"assistant","requestId":"req-sub-1","timestamp":"2026-09-04T10:00:03Z","apiBlockIndex":3,"message":{"usage":{"input_tokens":50,"output_tokens":311,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens_details":{"thinking_tokens":80}}}}
JSONL

out_f3=$(ccs-run-cost sess-3-subagent-shape --format json 2>/dev/null || true)
assert_eq "A2: subagent shape rows == 4" "4" "$(echo "$out_f3" | jq_val '.sessions[0].totals.rows')"
assert_eq "A2: subagent shape requests == 1" "1" "$(echo "$out_f3" | jq_val '.sessions[0].totals.requests')"
assert_eq "A2: subagent shape output == 311" "311" "$(echo "$out_f3" | jq_val '.sessions[0].totals.output')"
assert_eq "A2: subagent shape input == 50" "50" "$(echo "$out_f3" | jq_val '.sessions[0].totals.input')"
assert_eq "A2: subagent shape billable == 361" "361" "$(echo "$out_f3" | jq_val '.sessions[0].totals.billable')"
assert_eq "A2: subagent shape thinking == 80" "80" "$(echo "$out_f3" | jq_val '.sessions[0].totals.thinking')"

echo "=== Fixture 4 & A3: Subagent accounting & attribution ==="
F4="$PROJECTS_DIR/sess-4-parent.jsonl"
cat > "$F4" <<'JSONL'
{"type":"assistant","requestId":"req-p-1","timestamp":"2026-09-04T10:00:00Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens_details":{"thinking_tokens":0}}}}
JSONL
mkdir -p "$PROJECTS_DIR/sess-4-parent/subagents"
cat > "$PROJECTS_DIR/sess-4-parent/subagents/agent-sub1.jsonl" <<'JSONL'
{"type":"assistant","requestId":"req-s1-1","timestamp":"2026-09-04T10:05:00Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":5,"output_tokens":30,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens_details":{"thinking_tokens":10}}}}
JSONL
cat > "$PROJECTS_DIR/sess-4-parent/subagents/agent-sub2.jsonl" <<'JSONL'
{"type":"assistant","requestId":"req-s2-1","timestamp":"2026-09-04T10:10:00Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":5,"output_tokens":20,"cache_read_input_tokens":20,"cache_creation_input_tokens":5,"output_tokens_details":{"thinking_tokens":5}}}}
JSONL

out_f4=$(ccs-run-cost sess-4-parent --format json 2>/dev/null || true)
assert_eq "A3: parent totals output == 100" "100" "$(echo "$out_f4" | jq_val '.sessions[0].totals.output')"
assert_eq "A3: parent totals billable == 110" "110" "$(echo "$out_f4" | jq_val '.sessions[0].totals.billable')"
assert_eq "A3: subagents length == 2" "2" "$(echo "$out_f4" | jq_val '.sessions[0].subagents | length')"
assert_eq "A3: subagent 1 id == agent-sub1" "agent-sub1" "$(echo "$out_f4" | jq_val '.sessions[0].subagents[0].id')"
assert_eq "A3: subagent 1 output == 30" "30" "$(echo "$out_f4" | jq_val '.sessions[0].subagents[0].totals.output')"
assert_eq "A3: subagent 2 id == agent-sub2" "agent-sub2" "$(echo "$out_f4" | jq_val '.sessions[0].subagents[1].id')"
assert_eq "A3: subagent 2 output == 20" "20" "$(echo "$out_f4" | jq_val '.sessions[0].subagents[1].totals.output')"
assert_eq "A3: with_subagents rows == 3" "3" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.rows')"
assert_eq "A3: with_subagents requests == 3" "3" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.requests')"
assert_eq "A3: with_subagents input == 20" "20" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.input')"
assert_eq "A3: with_subagents output == 150" "150" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.output')"
assert_eq "A3: with_subagents billable == 170" "170" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.billable')"
assert_eq "A3: with_subagents cache_read == 30" "30" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.cache_read')"
assert_eq "A3: with_subagents cache_creation == 5" "5" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.cache_creation')"
assert_eq "A3: with_subagents thinking == 15" "15" "$(echo "$out_f4" | jq_val '.sessions[0].with_subagents.thinking')"

out_f4_nosub=$(ccs-run-cost sess-4-parent --no-subagents --format json 2>/dev/null || true)
assert_eq "A3: no-subagents subagents length == 0" "0" "$(echo "$out_f4_nosub" | jq_val '.sessions[0].subagents | length')"
assert_eq "A3: no-subagents with_subagents output == 100" "100" "$(echo "$out_f4_nosub" | jq_val '.sessions[0].with_subagents.output')"
assert_eq "A3: no-subagents with_subagents billable == 110" "110" "$(echo "$out_f4_nosub" | jq_val '.sessions[0].with_subagents.billable')"

echo "=== Fixture 5 & A4: Gemini provider session (no usage) ==="
F5="$PROJECTS_DIR/sess-5-gemini.json"
cat > "$F5" <<'JSON'
{"startTime":"2026-09-04T10:00:00Z","lastUpdated":"2026-09-04T10:10:00Z","messages":[{"type":"user","content":"hello"},{"type":"gemini","content":"hi"}]}
JSON

out_f5=$(ccs-run-cost sess-5-gemini --format json 2>/dev/null || true)
assert_eq "A4: gemini provider == gemini" "gemini" "$(echo "$out_f5" | jq_val '.sessions[0].provider')"
assert_eq "A4: gemini usage_available == false" "false" "$(echo "$out_f5" | jq_val '.sessions[0].usage_available')"
assert_eq "A4: gemini totals output == 0" "0" "$(echo "$out_f5" | jq_val '.sessions[0].totals.output')"
assert_eq "A4: gemini totals billable == 0" "0" "$(echo "$out_f5" | jq_val '.sessions[0].totals.billable')"
assert_eq "A4: gemini totals rows == 0" "0" "$(echo "$out_f5" | jq_val '.sessions[0].totals.rows')"
assert_eq "A4: gemini totals requests == 0" "0" "$(echo "$out_f5" | jq_val '.sessions[0].totals.requests')"

out_f5_md=$(ccs-run-cost sess-5-gemini --format md 2>/dev/null || true)
assert_contains "A4: gemini md contains usage 不可得" "$out_f5_md" "usage 不可得"
assert_contains "A4: gemini md contains [usage unavailable] token" "$out_f5_md" "[usage unavailable]"

echo "=== Fixture 6 & A5: Stage split boundary ==="
F6="$PROJECTS_DIR/sess-6-split.jsonl"
cat > "$F6" <<'JSONL'
{"type":"assistant","requestId":"req-split-1","timestamp":"2026-09-04T11:59:59Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens_details":{"thinking_tokens":0}}}}
{"type":"assistant","requestId":"req-split-2","timestamp":"2026-09-04T12:00:00Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":15,"output_tokens":25,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens_details":{"thinking_tokens":0}}}}
{"type":"assistant","requestId":"req-split-3","timestamp":"2026-09-04T12:00:01Z","apiBlockIndex":0,"message":{"usage":{"input_tokens":30,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens_details":{"thinking_tokens":0}}}}
JSONL

out_f6=$(ccs-run-cost sess-6-split --split 2026-09-04T12:00:00Z --format json 2>/dev/null || true)
assert_eq "A5: stages length == 2" "2" "$(echo "$out_f6" | jq_val '.sessions[0].stages | length')"
assert_eq "A5: stage 0 output == 20" "20" "$(echo "$out_f6" | jq_val '.sessions[0].stages[0].output')"
assert_eq "A5: stage 0 billable == 30" "30" "$(echo "$out_f6" | jq_val '.sessions[0].stages[0].billable')"
assert_eq "A5: stage 0 requests == 1" "1" "$(echo "$out_f6" | jq_val '.sessions[0].stages[0].requests')"
assert_eq "A5: stage 1 output == 75" "75" "$(echo "$out_f6" | jq_val '.sessions[0].stages[1].output')"
assert_eq "A5: stage 1 billable == 120" "120" "$(echo "$out_f6" | jq_val '.sessions[0].stages[1].billable')"
assert_eq "A5: stage 1 requests == 2" "2" "$(echo "$out_f6" | jq_val '.sessions[0].stages[1].requests')"
assert_eq "A5: totals output == 95" "95" "$(echo "$out_f6" | jq_val '.sessions[0].totals.output')"
assert_eq "A5: totals billable == 150" "150" "$(echo "$out_f6" | jq_val '.sessions[0].totals.billable')"

echo "=== Fixture 8 & A6: Until boundary & Reproducibility ==="
out_f8_run1=$(ccs-run-cost sess-6-split --until 2026-09-04T12:00:00Z --format json 2>/dev/null || true)
assert_eq "A6: until run1 non-empty" "true" "$([ -n "$out_f8_run1" ] && echo true || echo false)"
assert_eq "A6: until rows == 2" "2" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.rows')"
assert_eq "A6: until requests == 2" "2" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.requests')"
assert_eq "A6: until input == 25" "25" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.input')"
assert_eq "A6: until output == 45" "45" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.output')"
assert_eq "A6: until billable == 70" "70" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.billable')"
assert_eq "A6: until cache_read == 0" "0" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.cache_read')"
assert_eq "A6: until cache_creation == 0" "0" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.cache_creation')"
assert_eq "A6: until thinking == 0" "0" "$(echo "$out_f8_run1" | jq_val '.sessions[0].totals.thinking')"

norm_run() { echo "$1" | jq -S 'del(.generated_at)'; }
out_f8_run2=$(ccs-run-cost sess-6-split --until 2026-09-04T12:00:00Z --format json 2>/dev/null || true)
assert_eq "A6: until run1 and run2 reproducible" "$(norm_run "$out_f8_run1")" "$(norm_run "$out_f8_run2")"

echo "=== Fixture 7: Missing requestId ==="
F7="$PROJECTS_DIR/sess-7-missing-reqid.jsonl"
cat > "$F7" <<'JSONL'
{"type":"assistant","uuid":"uuid-aaa-111","timestamp":"2026-09-04T10:00:00Z","message":{"usage":{"input_tokens":12,"output_tokens":24,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens_details":{"thinking_tokens":4}}}}
{"type":"assistant","uuid":"uuid-bbb-222","timestamp":"2026-09-04T10:01:00Z","message":{"usage":{"input_tokens":18,"output_tokens":36,"cache_read_input_tokens":200,"cache_creation_input_tokens":20,"output_tokens_details":{"thinking_tokens":6}}}}
JSONL

out_f7=$(ccs-run-cost sess-7-missing-reqid --format json 2>/dev/null || true)
assert_eq "F7: missing reqid rows == 2" "2" "$(echo "$out_f7" | jq_val '.sessions[0].totals.rows')"
assert_eq "F7: missing reqid requests == 2" "2" "$(echo "$out_f7" | jq_val '.sessions[0].totals.requests')"
assert_eq "F7: missing reqid input == 30" "30" "$(echo "$out_f7" | jq_val '.sessions[0].totals.input')"
assert_eq "F7: missing reqid output == 60" "60" "$(echo "$out_f7" | jq_val '.sessions[0].totals.output')"
assert_eq "F7: missing reqid billable == 90" "90" "$(echo "$out_f7" | jq_val '.sessions[0].totals.billable')"
assert_eq "F7: missing reqid cache_read == 300" "300" "$(echo "$out_f7" | jq_val '.sessions[0].totals.cache_read')"
assert_eq "F7: missing reqid cache_creation == 30" "30" "$(echo "$out_f7" | jq_val '.sessions[0].totals.cache_creation')"
assert_eq "F7: missing reqid thinking == 10" "10" "$(echo "$out_f7" | jq_val '.sessions[0].totals.thinking')"

echo "=== Multi-session & Grand total ==="
out_multi=$(ccs-run-cost sess-1-single sess-2-main --format json 2>/dev/null || true)
assert_eq "multi: sessions length == 2" "2" "$(echo "$out_multi" | jq_val '.sessions | length')"
assert_eq "multi: grand_total output == 320" "320" "$(echo "$out_multi" | jq_val '.grand_total.output')"
assert_eq "multi: grand_total billable == 430" "430" "$(echo "$out_multi" | jq_val '.grand_total.billable')"
assert_eq "multi: grand_total requests == 2" "2" "$(echo "$out_multi" | jq_val '.grand_total.requests')"

echo "=== Markdown format & Disclaimer & Label ==="
out_f1_md=$(ccs-run-cost sess-1-single --label sess-1-single=worker-1 --format md 2>/dev/null || true)
assert_contains "md: disclaimer present" "$out_f1_md" "本報告僅涵蓋可取得 usage 的 provider。"
assert_contains "md: label rendered" "$out_f1_md" "worker-1"

echo "=== CLI Help & Error handling ==="
help_out=$(ccs-run-cost --help 2>&1 || true)
assert_contains "cli: help flag" "$help_out" "Usage: ccs-run-cost"

err_out=$(ccs-run-cost non-existent-session-id 2>&1 || true)
assert_contains "cli: unresolvable session errors" "$err_out" "non-existent-session-id"

echo "=== B1 & Flag combo: --split x --format md ==="
out_split_md=$(ccs-run-cost sess-6-split --split 2026-09-04T12:00:00Z 2>/dev/null || true)
rc_split_md=$(ccs-run-cost sess-6-split --split 2026-09-04T12:00:00Z >/dev/null 2>&1 && echo 0 || echo $?)
assert_eq "B1: split x md exits 0" "0" "$rc_split_md"
assert_contains "B1: split x md contains stages header" "$out_split_md" "### Stages Breakdown:"
assert_contains "B1: split x md contains Stage 0" "$out_split_md" "| Stage 0 |"
assert_contains "B1: split x md contains Stage 1" "$out_split_md" "| Stage 1 |"

echo "=== Flag combo: --split x --until ==="
out_split_until=$(ccs-run-cost sess-6-split --split 2026-09-04T12:00:00Z --until 2026-09-04T12:00:00Z --format json 2>/dev/null || true)
assert_eq "split x until: stage 0 requests == 1" "1" "$(echo "$out_split_until" | jq_val '.sessions[0].stages[0].requests')"
assert_eq "split x until: stage 1 requests == 1" "1" "$(echo "$out_split_until" | jq_val '.sessions[0].stages[1].requests')"
assert_eq "split x until: total requests == 2" "2" "$(echo "$out_split_until" | jq_val '.sessions[0].totals.requests')"
assert_eq "split x until: total output == 45" "45" "$(echo "$out_split_until" | jq_val '.sessions[0].totals.output')"

echo "=== Flag combo: multiple splits in reverse order & precision ==="
out_split_rev=$(ccs-run-cost sess-6-split --split 2026-09-04T12:00:00.5Z --split 2026-09-04T12:00:00Z --format json 2>/dev/null || true)
assert_eq "split rev: stages length == 3" "3" "$(echo "$out_split_rev" | jq_val '.sessions[0].stages | length')"
assert_eq "split rev: stage 0 to is 12:00:00Z" "2026-09-04T12:00:00Z" "$(echo "$out_split_rev" | jq_val '.sessions[0].stages[0].to')"
assert_eq "split rev: stage 1 to is 12:00:00.5Z" "2026-09-04T12:00:00.5Z" "$(echo "$out_split_rev" | jq_val '.sessions[0].stages[1].to')"

echo "=== Flag combo: Gemini session x --split ==="
out_gem_split_md=$(ccs-run-cost sess-5-gemini --split 2026-09-04T12:00:00Z 2>/dev/null || true)
rc_gem_split_md=$(ccs-run-cost sess-5-gemini --split 2026-09-04T12:00:00Z >/dev/null 2>&1 && echo 0 || echo 1)
assert_eq "gemini x split exits 0" "0" "$rc_gem_split_md"
assert_contains "gemini x split contains stages breakdown" "$out_gem_split_md" "### Stages Breakdown:"

echo "=== B2: Timestamp validation for --until and --split ==="
err_until_bare=$(ccs-run-cost sess-1-single --until 2026-09-04 2>&1 || true)
rc_until_bare=$(ccs-run-cost sess-1-single --until 2026-09-04 >/dev/null 2>&1 && echo 0 || echo 1)
assert_eq "B2: until bare date exits non-zero" "1" "$rc_until_bare"
assert_contains "B2: until bare date error message" "$err_until_bare" "invalid ISO8601 timestamp"

err_until_garb=$(ccs-run-cost sess-1-single --until garbage 2>&1 || true)
rc_until_garb=$(ccs-run-cost sess-1-single --until garbage >/dev/null 2>&1 && echo 0 || echo 1)
assert_eq "B2: until garbage exits non-zero" "1" "$rc_until_garb"
assert_contains "B2: until garbage error message" "$err_until_garb" "invalid ISO8601 timestamp"

err_until_tz=$(ccs-run-cost sess-1-single --until 2026-09-04T19:00:00+08:00 2>&1 || true)
rc_until_tz=$(ccs-run-cost sess-1-single --until 2026-09-04T19:00:00+08:00 >/dev/null 2>&1 && echo 0 || echo 1)
assert_eq "B2: until tz offset exits non-zero" "1" "$rc_until_tz"
assert_contains "B2: until tz offset error message" "$err_until_tz" "invalid ISO8601 timestamp"

err_split_bare=$(ccs-run-cost sess-1-single --split 2026-09-04 2>&1 || true)
rc_split_bare=$(ccs-run-cost sess-1-single --split 2026-09-04 >/dev/null 2>&1 && echo 0 || echo 1)
assert_eq "B2: split bare date exits non-zero" "1" "$rc_split_bare"
assert_contains "B2: split bare date error message" "$err_split_bare" "invalid ISO8601 timestamp"

echo "=== B3: Corrupted / truncated session handling ==="
F_TRUNC="$PROJECTS_DIR/sess-trunc.jsonl"
cat > "$F_TRUNC" <<'JSONL'
{"type":"assistant","uuid":"uuid-trunc-1","timestamp":"2026-09-04T10:00:00Z","message":{"usage":{"input_tokens":10,"output_tokens":20}}}
{"type":"assistant","uuid":"uuid-trunc-2","timestamp":"2026-09-04T10:01:00Z","message":{"usa
JSONL

err_trunc=$(ccs-run-cost sess-1-single sess-trunc --format json 2>&1 1>/dev/null || true)
assert_contains "B3: trunc session warns on stderr" "$err_trunc" "failed to parse session"

out_trunc_json=$(ccs-run-cost sess-1-single sess-trunc --format json 2>/dev/null || true)
assert_eq "B3: trunc session retained in sessions array" "2" "$(echo "$out_trunc_json" | jq_val '.sessions | length')"
assert_eq "B3: trunc session usage_available is false" "false" "$(echo "$out_trunc_json" | jq_val '.sessions[1].usage_available')"
assert_eq "B3: trunc session not in grand_total output" "20" "$(echo "$out_trunc_json" | jq_val '.grand_total.output')"

out_trunc_md=$(ccs-run-cost sess-trunc 2>/dev/null || true)
assert_contains "B3: trunc session md shows unavailable" "$out_trunc_md" "[usage unavailable] / usage 不可得"

echo "=== B4: Resolved UUID in sid & Deduplication of same sid ==="
F_PREFIX="$PROJECTS_DIR/sess-prefix-full-uuid-12345.jsonl"
cat > "$F_PREFIX" <<'JSONL'
{"type":"assistant","uuid":"u1","timestamp":"2026-09-04T10:00:00Z","message":{"usage":{"input_tokens":5,"output_tokens":10}}}
JSONL

out_prefix_json=$(ccs-run-cost sess-prefix --format json 2>/dev/null || true)
assert_eq "B4: sid contains full resolved uuid not prefix" "sess-prefix-full-uuid-12345" "$(echo "$out_prefix_json" | jq_val '.sessions[0].sid')"

out_dup_json=$(ccs-run-cost sess-prefix sess-prefix-full-uuid-12345 --format json 2>/dev/null || true)
assert_eq "B4: duplicate sid only counted once in sessions" "1" "$(echo "$out_dup_json" | jq_val '.sessions | length')"
assert_eq "B4: duplicate sid grand_total output not doubled" "10" "$(echo "$out_dup_json" | jq_val '.grand_total.output')"

echo "=== Nit 1: Unknown format returns 1 ==="
err_fmt=$(ccs-run-cost sess-1-single --format xml 2>&1 || true)
rc_fmt=$(ccs-run-cost sess-1-single --format xml >/dev/null 2>&1 && echo 0 || echo 1)
assert_eq "nit 1: unknown format exits non-zero" "1" "$rc_fmt"
assert_contains "nit 1: unknown format error message" "$err_fmt" "unknown format 'xml'"

test_summary
