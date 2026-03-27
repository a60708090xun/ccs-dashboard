#!/usr/bin/env bash
# tests/e2e/test-overview-e2e.sh
# E2E scenarios for ccs-overview including
# crash banner expiry (GH#6).
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/fixture-helper.sh
source tests/e2e/e2e-helper.sh
ROOT="$(pwd)"
source "$ROOT/ccs-dashboard.sh"

# Ensure pick-index dir exists
mkdir -p "$HOME/.claude"

# ── Common mocks ──
_ccs_get_boot_epoch() { echo "1000000000"; }
_ccs_resolve_project_path() { echo "/fake"; }
_ccs_is_archived() { return 1; }
_ccs_topic_from_jsonl() { echo "test topic"; }
_ccs_overview_session_data() {
  cat <<'JSON'
{"last_exchange":{"user":"test","assistant":"ok"},"todos":[]}
JSON
}
_ccs_health_badge() { printf ''; }
_ccs_health_badge_md() { echo ''; }

echo "=== E2E: ccs-overview ==="

# ── Scenario 1: Basic output — 2 projects ──
echo ""
echo "--- Scenario: basic output ---"
setup_e2e_dir "overview-basic"
mock_no_active_process

S1=$(create_mock_session \
  "-proj-alpha" \
  "aaaa1111-0000-0000-0000-000000000001")
cat > "$S1" <<'JSONL'
{"type":"user","message":{"content":"hello alpha"},"timestamp":"2026-03-26T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp":"2026-03-26T09:01:00Z"}
JSONL
touch "$S1"

S2=$(create_mock_session \
  "-proj-beta" \
  "bbbb2222-0000-0000-0000-000000000001")
cat > "$S2" <<'JSONL'
{"type":"user","message":{"content":"hello beta"},"timestamp":"2026-03-26T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp":"2026-03-26T09:01:00Z"}
JSONL
touch "$S2"

_ccs_detect_crash() {
  local -n _out=$1
}

set +eu
out=$(ccs-overview --md 2>/dev/null)
set -eu

assert_contains "basic: proj/alpha in output" \
  "$out" "proj/alpha"
assert_contains "basic: proj/beta in output" \
  "$out" "proj/beta"
assert_contains "basic: session count" \
  "$out" "Active Sessions (2)"

# ── Scenario 2: Crash banner shows ──
echo ""
echo "--- Scenario: crash banner shows ---"
setup_e2e_dir "overview-crash"
mock_no_active_process

S1=$(create_mock_session \
  "-proj-crash" \
  "cccc3333-0000-0000-0000-000000000001")
cat > "$S1" <<'JSONL'
{"type":"user","message":{"content":"work on crash"},"timestamp":"2026-03-26T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-26T09:01:00Z"}
JSONL
touch "$S1"

_ccs_detect_crash() {
  local -n _out=$1
  _out["cccc3333-0000-0000-0000-000000000001"]="high:reboot"
}

set +eu
out=$(ccs-overview --md 2>/dev/null)
set -eu

assert_contains "crash: banner shows" \
  "$out" "crash-interrupted"
assert_contains "crash: count in banner" \
  "$out" "1 個 crash-interrupted"

# ── Scenario 3: Crash banner expiry (GH#6) ──
echo ""
echo "--- Scenario: crash expiry (GH#6) ---"
setup_e2e_dir "overview-expiry"
mock_no_active_process

S1=$(create_mock_session \
  "-proj-old" \
  "dddd4444-0000-0000-0000-000000000001")
cat > "$S1" <<'JSONL'
{"type":"user","message":{"content":"old session"},"timestamp":"2026-03-20T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-20T09:01:00Z"}
JSONL
# Make file old but within 7-day window
# so _ccs_collect_sessions still picks it up.
# 5000 min = ~3.47 days > 4320 min = 3 days
touch_minutes_ago "$S1" 5000

_ccs_detect_crash() {
  local -n _out=$1
  _out["dddd4444-0000-0000-0000-000000000001"]="high:reboot-idle"
}

set +eu
out=$(ccs-overview --md 2>/dev/null)
set -eu

# Crash banner should NOT appear (expired)
assert_not_contains "expiry: no crash banner" \
  "$out" "crash-interrupted"
# Session should still appear (within 7 days)
assert_contains "expiry: session still listed" \
  "$out" "dddd4444"

# ── Scenario 4: Mixed — old + fresh crash ──
echo ""
echo "--- Scenario: mixed crash ---"
setup_e2e_dir "overview-mixed"
mock_no_active_process

# Old crash (>3 days)
S1=$(create_mock_session \
  "-proj-old" \
  "eeee5555-0000-0000-0000-000000000001")
cat > "$S1" <<'JSONL'
{"type":"user","message":{"content":"old crash"},"timestamp":"2026-03-20T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-20T09:01:00Z"}
JSONL
touch_minutes_ago "$S1" 5000

# Fresh crash (<3 days)
S2=$(create_mock_session \
  "-proj-new" \
  "ffff6666-0000-0000-0000-000000000001")
cat > "$S2" <<'JSONL'
{"type":"user","message":{"content":"fresh crash"},"timestamp":"2026-03-27T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-27T09:01:00Z"}
JSONL
touch "$S2"

_ccs_detect_crash() {
  local -n _out=$1
  _out["eeee5555-0000-0000-0000-000000000001"]="high:reboot-idle"
  _out["ffff6666-0000-0000-0000-000000000001"]="high:reboot"
}

set +eu
out=$(ccs-overview --md 2>/dev/null)
set -eu

# Banner should show 1 crash (only fresh)
assert_contains "mixed: crash banner shows" \
  "$out" "crash-interrupted"
assert_contains "mixed: 1 crash in banner" \
  "$out" "1 個 crash-interrupted"
# Fresh crash session gets red emoji
assert_contains "mixed: fresh crash listed" \
  "$out" "ffff6666"

test_summary
