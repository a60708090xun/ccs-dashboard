#!/usr/bin/env bash
# tests/test-crash-clean-by-id.sh
# Run: bash tests/test-crash-clean-by-id.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tests/fixture-helper.sh"
source "$ROOT/ccs-core.sh"
source "$ROOT/ccs-ops.sh"

setup_test_dir "crash-clean-by-id"

# ── Build mock sessions ──
MOCK_PROJ="$TEST_DIR/projects/-mock-project"
mkdir -p "$MOCK_PROJ"

# Session A: d25fd727-...
SA="$MOCK_PROJ/d25fd727-0000-0000-0000-000000000001.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"

# Session B: d25f1111-...
SB="$MOCK_PROJ/d25f1111-0000-0000-0000-000000000002.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"

# Session C: abcd0000-...
SC="$MOCK_PROJ/abcd0000-0000-0000-0000-000000000003.jsonl"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"

# Build crash_map and session_files arrays
declare -A crash_map=(
  ["d25fd727-0000-0000-0000-000000000001"]="high:reboot"
  ["d25f1111-0000-0000-0000-000000000002"]="low:idle"
  ["abcd0000-0000-0000-0000-000000000003"]="high:reboot"
)
session_files=("$SA" "$SB" "$SC")
session_projects=(
  "-mock-project"
  "-mock-project"
  "-mock-project"
)

# ── Mock _ccs_topic_from_jsonl ──
_ccs_topic_from_jsonl() { echo "test topic"; }

echo "=== Test 1: exact match — single ID ==="
out=$(_ccs_crash_clean_by_id \
  crash_map session_files \
  "d25fd727-0000-0000-0000-000000000001")
assert_contains "archived d25fd727" "$out" "d25fd727"
assert_contains "shows checkmark" "$out" "✓"
# Verify file actually archived
last=$(tail -1 "$SA")
assert_eq "last-prompt marker" \
  '{"type":"last-prompt"}' "$last"

echo ""
echo "=== Test 2: prefix match — unique ==="
# Reset session C
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files \
  "abcd")
assert_contains "archived abcd0000" "$out" "abcd0000"
last=$(tail -1 "$SC")
assert_eq "last-prompt marker" \
  '{"type":"last-prompt"}' "$last"

echo ""
echo "=== Test 3: prefix match — ambiguous ==="
# Reset sessions
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files \
  "d25f") || true
assert_contains "ambiguous error" "$out" "ambiguous"
assert_contains "lists match 1" "$out" "d25fd727"
assert_contains "lists match 2" "$out" "d25f1111"
# Verify NOT archived
last_a=$(tail -1 "$SA")
last_b=$(tail -1 "$SB")
assert_not_contains "SA not archived" \
  "$last_a" "last-prompt"
assert_not_contains "SB not archived" \
  "$last_b" "last-prompt"

echo ""
echo "=== Test 4: no match ==="
out=$(_ccs_crash_clean_by_id \
  crash_map session_files \
  "zzzzz") || true
assert_contains "not found" "$out" "not found"

echo ""
echo "=== Test 5: multiple IDs ==="
# Reset all
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files \
  "d25fd727-0000-0000-0000-000000000001" \
  "abcd")
assert_contains "archived d25fd727" "$out" "d25fd727"
assert_contains "archived abcd0000" "$out" "abcd0000"
last_a=$(tail -1 "$SA")
last_c=$(tail -1 "$SC")
assert_eq "SA archived" \
  '{"type":"last-prompt"}' "$last_a"
assert_eq "SC archived" \
  '{"type":"last-prompt"}' "$last_c"

echo ""
echo "=== Test 6: mixed — one valid, one bad ==="
# Reset SA
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
out=$(_ccs_crash_clean_by_id \
  crash_map session_files \
  "d25fd727-0000-0000-0000-000000000001" \
  "zzzzz") || true
assert_contains "archived d25fd727" "$out" "d25fd727"
assert_contains "zzzzz not found" "$out" "not found"

echo ""
echo "=== Test 7: summary omits zero counts ==="
out=$(_ccs_crash_clean_by_id \
  crash_map session_files \
  "zzz1" "zzz2") || true
assert_not_contains "no zero archived" \
  "$out" "0 archived"
assert_contains "shows not found" \
  "$out" "2 not found"

echo ""
echo "=== Test 8: non-zero return on failure ==="
rc=0
_ccs_crash_clean_by_id \
  crash_map session_files \
  "nonexistent" >/dev/null 2>&1 || rc=$?
assert_eq "returns non-zero on not found" "1" "$rc"

echo ""
echo "=== Test 9: ccs-crash --clean <id> end-to-end ==="

# Mock _ccs_collect_sessions to use our test data
_ccs_collect_sessions() {
  local show_all=false
  if [ "${1:-}" = "--all" ]; then
    show_all=true; shift
  fi
  local -n _of=$1 _op=$2 _or=$3
  _of=("$SA" "$SB" "$SC")
  _op=("-mock-project" "-mock-project" "-mock-project")
  _or=("mock-row" "mock-row" "mock-row")
}

# Mock _ccs_detect_crash to populate crash_map
_ccs_detect_crash() {
  local -n _cm=$1
  _cm=(
    ["d25fd727-0000-0000-0000-000000000001"]="high:reboot"
    ["d25f1111-0000-0000-0000-000000000002"]="low:idle"
    ["abcd0000-0000-0000-0000-000000000003"]="high:reboot"
  )
}

# Reset sessions
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SA"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SC"

out=$(ccs-crash --clean abcd 2>&1)
assert_contains "e2e archive abcd" "$out" "abcd0000"
assert_contains "e2e checkmark" "$out" "✓"
last=$(tail -1 "$SC")
assert_eq "e2e last-prompt" \
  '{"type":"last-prompt"}' "$last"

echo ""
echo "=== Test 10: low confidence session ==="
echo "=== reachable by --clean <id> ==="

# Reset SB (low confidence)
printf '{"type":"user","message":{"content":"hello"}}\n' > "$SB"

out=$(ccs-crash --clean d25f1111 2>&1)
assert_contains "low-conf archived" "$out" "d25f1111"
last=$(tail -1 "$SB")
assert_eq "low-conf last-prompt" \
  '{"type":"last-prompt"}' "$last"

echo ""
test_summary
