#!/usr/bin/env bash
# tests/test-status.sh — crash expiry + stale hint tests
# Run: bash tests/test-status.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh
source ccs-ops.sh

setup_test_dir "status"

# ── Mock heavy dependencies ──
_ccs_get_boot_epoch() { echo "1000000000"; }
_ccs_overview_session_data() {
  echo '{"last_exchange":{"user":"test"},"todos":[]}'
}
_ccs_resolve_project_path() { echo "/fake"; }
_ccs_topic_from_jsonl() { echo "test topic"; }

echo "=== _ccs_crash_md: stale hint ==="

# Case A: 1 old crash (>3 days) + 1 fresh crash (<3 days)
# → hint should appear with count 1
A_OLD="$TEST_DIR/aaaa1111-0000-0000-0000-000000000001.jsonl"
A_FRESH="$TEST_DIR/bbbb2222-0000-0000-0000-000000000002.jsonl"
cat > "$A_OLD" <<'JSONL'
{"type":"user","message":{"content":"old session"},"timestamp":"2026-03-20T09:00:00Z"}
JSONL
cat > "$A_FRESH" <<'JSONL'
{"type":"user","message":{"content":"fresh session"},"timestamp":"2026-03-25T09:00:00Z"}
JSONL
touch_minutes_ago "$A_OLD" 5000
touch_minutes_ago "$A_FRESH" 100

declare -A map_a=(
  ["aaaa1111-0000-0000-0000-000000000001"]="high:reboot"
  ["bbbb2222-0000-0000-0000-000000000002"]="high:hung"
)
files_a=("$A_OLD" "$A_FRESH")
projects_a=("test-project" "test-project")
rows_a=("test-project	5000	" "test-project	100	")

out_a=$(_ccs_crash_md map_a files_a projects_a rows_a 2>/dev/null)
assert_contains "A: stale hint present" \
  "$out_a" "older than 3 days"
assert_contains "A: stale count is 1" \
  "$out_a" "**1** session(s)"

# Case B: only fresh crashes (<3 days)
# → hint should NOT appear
B_FRESH="$TEST_DIR/cccc3333-0000-0000-0000-000000000003.jsonl"
cat > "$B_FRESH" <<'JSONL'
{"type":"user","message":{"content":"recent"},"timestamp":"2026-03-25T09:00:00Z"}
JSONL
touch_minutes_ago "$B_FRESH" 100

declare -A map_b=(
  ["cccc3333-0000-0000-0000-000000000003"]="high:hung"
)
files_b=("$B_FRESH")
projects_b=("test-project")
rows_b=("test-project	100	")

out_b=$(_ccs_crash_md map_b files_b projects_b rows_b 2>/dev/null)
assert_not_contains "B: no stale hint" \
  "$out_b" "older than 3 days"

# Case C: all old crashes (>3 days)
# → hint should show count = 2
C1="$TEST_DIR/dddd4444-0000-0000-0000-000000000004.jsonl"
C2="$TEST_DIR/eeee5555-0000-0000-0000-000000000005.jsonl"
cat > "$C1" <<'JSONL'
{"type":"user","message":{"content":"old1"},"timestamp":"2026-03-18T09:00:00Z"}
JSONL
cat > "$C2" <<'JSONL'
{"type":"user","message":{"content":"old2"},"timestamp":"2026-03-18T09:00:00Z"}
JSONL
touch_minutes_ago "$C1" 5000
touch_minutes_ago "$C2" 6000

declare -A map_c=(
  ["dddd4444-0000-0000-0000-000000000004"]="high:reboot-idle"
  ["eeee5555-0000-0000-0000-000000000005"]="high:non-reboot"
)
files_c=("$C1" "$C2")
projects_c=("test-project" "test-project")
rows_c=("test-project	5000	" "test-project	6000	")

out_c=$(_ccs_crash_md map_c files_c projects_c rows_c 2>/dev/null)
assert_contains "C: stale hint present" \
  "$out_c" "older than 3 days"
assert_contains "C: stale count is 2" \
  "$out_c" "**2** session(s)"

# ══════════════════════════════════════
# E2E: ccs-status crash expiry (fix #2)
# ══════════════════════════════════════

echo ""
echo "=== ccs-status: crash expiry (E2E) ==="

# Need ccs-status from ccs-dashboard.sh
# Source with absolute path so BASH_SOURCE resolves correctly
ROOT="$(pwd)"
source "$ROOT/ccs-dashboard.sh"

# Re-define mocks (source ccs-dashboard.sh reloads all modules)
_ccs_get_boot_epoch() { echo "1000000000"; }
_ccs_resolve_project_path() { echo "/fake"; }
_ccs_is_archived() { return 1; }

# Build mock projects dir
MOCK_STATUS="$TEST_DIR/mock-status-projects"
MOCK_PROJ_DIR="$MOCK_STATUS/-mock-test-proj"
mkdir -p "$MOCK_PROJ_DIR"

# Session D1: crashed + old (>3 days) → should be STALE
D1="$MOCK_PROJ_DIR/d1d1d1d1-0000-0000-0000-000000000001.jsonl"
cat > "$D1" <<'JSONL'
{"type":"user","message":{"content":"old crashed"},"timestamp":"2026-03-20T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-20T09:01:00Z"}
JSONL
touch_minutes_ago "$D1" 5000

# Session D2: crashed + fresh (<3 days) → should be CRASHED
D2="$MOCK_PROJ_DIR/d2d2d2d2-0000-0000-0000-000000000002.jsonl"
cat > "$D2" <<'JSONL'
{"type":"user","message":{"content":"fresh crashed"},"timestamp":"2026-03-25T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-25T09:01:00Z"}
JSONL
touch_minutes_ago "$D2" 100

# Session D3: normal (not crashed, fresh) → should be ACTIVE
D3="$MOCK_PROJ_DIR/d3d3d3d3-0000-0000-0000-000000000003.jsonl"
cat > "$D3" <<'JSONL'
{"type":"user","message":{"content":"active session"},"timestamp":"2026-03-25T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-25T10:01:00Z"}
JSONL
touch "$D3"

# Mock _ccs_detect_crash: mark D1 and D2 as crashed
_ccs_detect_crash() {
  local -n _out=$1
  _out["d1d1d1d1-0000-0000-0000-000000000001"]="high:reboot-idle"
  _out["d2d2d2d2-0000-0000-0000-000000000002"]="high:hung"
}

# Mock _ccs_is_archived: nothing is archived
_ccs_is_archived() { return 1; }

# Run ccs-status in markdown mode
# Disable set -e: ccs-status may return non-zero
# from internal helpers (zombie detection etc.)
set +e
status_out=$(CCS_PROJECTS_DIR="$MOCK_STATUS" CCS_GEMINI_DIR="$MOCK_STATUS" \
  ccs-status --md 2>/dev/null)
set -e
# D1 (old crash >3d) should NOT appear in Crashed section
assert_not_contains \
  "D1: old crash not in Crashed" \
  "$status_out" \
  "d1d1d1d1"

# D2 (fresh crash <3d) SHOULD appear in Crashed section
assert_contains \
  "D2: fresh crash in output" \
  "$status_out" \
  "d2d2d2d2"

# D3 (normal) should appear in Active
assert_contains \
  "D3: active session in output" \
  "$status_out" \
  "d3d3d3d3"

# Stale section should exist (D1 demoted there)
assert_contains \
  "Stale section has count" \
  "$status_out" \
  "open session(s) untouched"

test_summary
