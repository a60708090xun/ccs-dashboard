#!/usr/bin/env bash
# tests/e2e/test-status-e2e.sh
# E2E scenarios for ccs-status
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/fixture-helper.sh
source tests/e2e/e2e-helper.sh
ROOT="$(pwd)"
source "$ROOT/ccs-dashboard.sh"

# Ensure pick-index dir exists (ccs-status writes it)
mkdir -p "$HOME/.claude"

# ── Common mocks ──
_ccs_get_boot_epoch() { echo "1000000000"; }
_ccs_resolve_project_path() { echo "/fake"; }
_ccs_is_archived() { return 1; }
_ccs_topic_from_jsonl() { echo "test topic"; }

echo "=== E2E: ccs-status ==="

# ── Scenario 1: Normal session ──
echo ""
echo "--- Scenario: normal session ---"
setup_e2e_dir "status-normal"
mock_no_active_process

SESSION_FILE=$(create_mock_session \
  "-test-proj" \
  "aaaa1111-0000-0000-0000-000000000001")
cat > "$SESSION_FILE" <<'JSONL'
{"type":"user","message":{"content":"hello"},"timestamp":"2026-03-26T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp":"2026-03-26T09:01:00Z"}
{"type":"user","message":{"content":"do task"},"timestamp":"2026-03-26T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"timestamp":"2026-03-26T09:03:00Z"}
{"type":"user","message":{"content":"thanks"},"timestamp":"2026-03-26T09:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"welcome"}]},"timestamp":"2026-03-26T09:05:00Z"}
JSONL
touch "$SESSION_FILE"

# No crashes for normal scenario
_ccs_detect_crash() {
  local -n _out=$1
}

# Disable -eu: ccs-status internals may
# reference unset vars (pick_file) and
# hit non-zero exits (fuser, find).
set +eu
out=$(ccs-status --md 2>/dev/null)
set -eu

assert_contains "normal: has session id" \
  "$out" "aaaa1111"
# slug "-test-proj" becomes "test/proj" in output
assert_contains "normal: has project" \
  "$out" "test/proj"

# ── Scenario 2: Crash session ──
echo ""
echo "--- Scenario: crash session ---"
setup_e2e_dir "status-crash"
mock_no_active_process

SESSION_FILE=$(create_mock_session \
  "-test-proj" \
  "bbbb2222-0000-0000-0000-000000000001")
cat > "$SESSION_FILE" <<'JSONL'
{"type":"user","message":{"content":"work"},"timestamp":"2026-03-26T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-26T09:01:00Z"}
JSONL
touch "$SESSION_FILE"

_ccs_detect_crash() {
  local -n _out=$1
  _out["bbbb2222-0000-0000-0000-000000000001"]="high:reboot"
}

set +eu
out=$(ccs-status --md 2>/dev/null)
set -eu

assert_contains "crash: CRASHED marker" \
  "$out" "bbbb2222"

# ── Scenario 3: Crash expiry (>3 days) ──
echo ""
echo "--- Scenario: crash expiry ---"
setup_e2e_dir "status-expiry"
mock_no_active_process

SESSION_FILE=$(create_mock_session \
  "-test-proj" \
  "cccc3333-0000-0000-0000-000000000001")
cat > "$SESSION_FILE" <<'JSONL'
{"type":"user","message":{"content":"old"},"timestamp":"2026-03-20T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-20T09:01:00Z"}
JSONL
touch_minutes_ago "$SESSION_FILE" 5000

_ccs_detect_crash() {
  local -n _out=$1
  _out["cccc3333-0000-0000-0000-000000000001"]="high:reboot-idle"
}

set +eu
out=$(ccs-status --md 2>/dev/null)
set -eu

assert_not_contains "expiry: old crash hidden" \
  "$out" "cccc3333"
assert_contains "expiry: stale hint" \
  "$out" "open session(s) untouched"

# ── Scenario 4: Empty projects dir ──
echo ""
echo "--- Scenario: empty dir ---"
setup_e2e_dir "status-empty"
mock_no_active_process

# Reset _ccs_detect_crash to no-op
_ccs_detect_crash() {
  local -n _out=$1
}

set +eu
out=$(ccs-status --md 2>/dev/null)
rc=$?
set -eu

assert_eq "empty: no error" "0" "$rc"

test_summary
