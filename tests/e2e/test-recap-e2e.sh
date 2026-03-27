#!/usr/bin/env bash
# tests/e2e/test-recap-e2e.sh
# E2E scenarios for ccs-recap
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/fixture-helper.sh
source tests/e2e/e2e-helper.sh
ROOT="$(pwd)"
source "$ROOT/ccs-dashboard.sh"

# ── Common mocks ──
_ccs_get_boot_epoch() { echo "1000000000"; }
_ccs_resolve_project_path() { echo "/fake"; }
_ccs_is_archived() { return 1; }
_ccs_topic_from_jsonl() { echo "test topic"; }
_ccs_detect_crash() { :; }

echo "=== E2E: ccs-recap ==="

# ── Scenario 1: Normal recap ──
echo ""
echo "--- Scenario: normal recap (2 projects) ---"
setup_e2e_dir "recap-normal"
mock_no_active_process

# Project A — session with 3 prompts
SF1=$(create_mock_session \
  "-proj-alpha" \
  "aaaa1111-0000-0000-0000-000000000001")
write_prompts "$SF1" 3
touch "$SF1"

# Project B — session with 4 prompts
SF2=$(create_mock_session \
  "-proj-beta" \
  "bbbb2222-0000-0000-0000-000000000002")
write_prompts "$SF2" 4
touch "$SF2"

set +eu
out_md=$(ccs-recap 7d --md 2>/dev/null)
out_json=$(ccs-recap 7d --json 2>/dev/null)
rc=$?
set -eu

assert_eq "normal: exit 0" "0" "$rc"
# --md output shows project name + topic
assert_contains "normal: has Daily Recap header" \
  "$out_md" "Daily Recap"
assert_contains "normal: proj alpha in md" \
  "$out_md" "alpha"
assert_contains "normal: proj beta in md" \
  "$out_md" "beta"
# --json output has full session IDs
assert_contains "normal: session aaaa in json" \
  "$out_json" "aaaa1111"
assert_contains "normal: session bbbb in json" \
  "$out_json" "bbbb2222"

# ── Scenario 2: Short session filtered ──
echo ""
echo "--- Scenario: short session filtered ---"
setup_e2e_dir "recap-short"
mock_no_active_process

# Session with only 1 user prompt (< 2 → filtered)
SF3=$(create_mock_session \
  "-proj-gamma" \
  "cccc3333-0000-0000-0000-000000000003")
write_prompts "$SF3" 1
touch "$SF3"

set +eu
out=$(ccs-recap 7d --md 2>/dev/null)
rc=$?
set -eu

# With 0 qualifying sessions, recap prints
# "No session activity" and exits 0
assert_eq "short: exit 0" "0" "$rc"
assert_not_contains \
  "short: session not in output" \
  "$out" "cccc3333"
assert_contains \
  "short: no activity message" \
  "$out" "No session activity"

# ── Scenario 3: Empty dir ──
echo ""
echo "--- Scenario: empty dir ---"
setup_e2e_dir "recap-empty"
mock_no_active_process

set +eu
out=$(ccs-recap 7d --md 2>/dev/null)
rc=$?
set -eu

assert_eq "empty: exit 0" "0" "$rc"
assert_contains "empty: no activity message" \
  "$out" "No session activity"

test_summary
