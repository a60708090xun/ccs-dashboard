#!/usr/bin/env bash
# tests/test-handoff.sh — ccs-handoff flag tests
# Run: bash tests/test-handoff.sh
#
# NOTE: source ccs-handoff.sh only (not
# ccs-dashboard.sh) because we only test
# flag parsing, which has no external deps.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh
source ccs-handoff.sh

echo "=== ccs-handoff flag handling ==="

# Case A: unknown flag rejected
ret_a=0
err_a=$(ccs-handoff --bogus 2>&1) \
  || ret_a=$?
assert_eq "A: unknown flag returns 1" \
  "1" "$ret_a"
assert_contains "A: unknown flag stderr" \
  "$err_a" "Unknown option"

# Case B: --help succeeds
ccs-handoff --help >/dev/null 2>&1
assert_eq "B: --help returns 0" "0" "$?"

# Case C: valid flag, no Unknown option
err_c=$(ccs-handoff --no-prompt \
  /nonexistent/path 2>&1 || true)
assert_not_contains "C: valid flag no Unknown" \
  "$err_c" "Unknown option"

# Case D: -n with value
err_d=$(ccs-handoff -n 3 \
  /nonexistent/path 2>&1 || true)
assert_not_contains "D: -n flag no Unknown" \
  "$err_d" "Unknown option"

# Case E: ccs-resume-prompt integration with ccs_resume.py
setup_test_dir "handoff_resume"
mock_jsonl="$TEST_DIR/myproject-a1c4f8e2-mock.jsonl"
cat << 'EOF' > "$mock_jsonl"
{"type":"user","message":{"content":"Hello"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Hi!"},{"type":"tool_use","name":"Read","input":{"file_path":"test.py"}}]}}
{"type":"user","isMeta":true,"message":{"content":"<local-command-stdout>print('hello')</local-command-stdout>"}}
{"type":"assistant","message":{"content":"Done!"}}
EOF

# Redefine _ccs_resolve_jsonl to return our mock file
_ccs_resolve_jsonl() {
  echo "$mock_jsonl"
}

# Redefine _ccs_resolve_project_path to return TEST_DIR
_ccs_resolve_project_path() {
  echo "$TEST_DIR"
}

prompt_out=$(ccs-resume-prompt --stdout 2>/dev/null)
assert_contains "E: prompt contains tool use marker" "$prompt_out" "🛠️"
assert_contains "E: prompt contains tool result marker" "$prompt_out" "📥"
assert_contains "E: prompt contains truncated tool output" "$prompt_out" "[content/output: print('hello')]"

test_summary
