#!/usr/bin/env bash
# tests/test-ops.sh — ccs-ops.sh function tests
# Run: bash tests/test-ops.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tests/fixture-helper.sh"
source "$ROOT/ccs-core.sh"
source "$ROOT/ccs-ops.sh"

setup_test_dir "ops"

# ── Build mock project directory ──
MOCK_PROJ="$TEST_DIR/projects/-mock-test-project"
mkdir -p "$MOCK_PROJ"

# ── Mock dependencies ──
_ccs_recap_scan_projects() {
  echo "-mock-test-project"
}
_ccs_resolve_project_path() {
  echo "/fake/path"
}
_ccs_is_archived() { return 1; }

echo "=== _ccs_recap_collect: short session filter ==="

# Case A: short session (1 non-meta user prompt) — should be SKIPPED
SHORT="$MOCK_PROJ/short111-0000-0000-0000-000000000001.jsonl"
cat > "$SHORT" <<'JSONL'
{"type":"user","message":{"content":"hello"},"timestamp":"2026-03-25T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"timestamp":"2026-03-25T09:01:00Z"}
JSONL
touch "$SHORT"

# Case B: normal session (3 non-meta user prompts) — should be INCLUDED
NORMAL="$MOCK_PROJ/norm2222-0000-0000-0000-000000000002.jsonl"
cat > "$NORMAL" <<'JSONL'
{"type":"user","message":{"content":"first question"},"timestamp":"2026-03-25T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"answer 1"}]},"timestamp":"2026-03-25T09:01:00Z"}
{"type":"user","message":{"content":"second question"},"timestamp":"2026-03-25T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"answer 2"}]},"timestamp":"2026-03-25T09:03:00Z"}
{"type":"user","message":{"content":"third question"},"timestamp":"2026-03-25T09:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"answer 3"}]},"timestamp":"2026-03-25T09:05:00Z"}
JSONL
touch "$NORMAL"

# Case C: meta-only session (2 prompts but all isMeta) — should be SKIPPED
META="$MOCK_PROJ/meta3333-0000-0000-0000-000000000003.jsonl"
cat > "$META" <<'JSONL'
{"type":"user","message":{"content":"meta1"},"isMeta":true,"timestamp":"2026-03-25T09:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-25T09:01:00Z"}
{"type":"user","message":{"content":"meta2"},"isMeta":true,"timestamp":"2026-03-25T09:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-25T09:03:00Z"}
JSONL
touch "$META"

# Use a from_epoch in the past (24 hours ago)
from_epoch=$(date -d "24 hours ago" +%s)

result=$(CCS_PROJECTS_DIR="$TEST_DIR/projects" \
  _ccs_recap_collect "$from_epoch" "all" 2>/dev/null)

# Extract session IDs from result
# Note: sessions use field "id" (not "sid") in the JSON output
sids=$(echo "$result" | jq -r \
  '.projects[].sessions[]?.id' 2>/dev/null)

# Case A: short session should NOT appear
if echo "$sids" | grep -q "short111"; then
  printf '  FAIL: short session short111 found in recap\n'
  FAIL=$((FAIL + 1))
else
  printf '  PASS: short session short111 filtered out\n'
  PASS=$((PASS + 1))
fi

# Case B: normal session SHOULD appear
if echo "$sids" | grep -q "norm2222"; then
  printf '  PASS: normal session norm2222 in recap\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL: normal session norm2222 missing from recap\n'
  FAIL=$((FAIL + 1))
fi

# Case C: meta-only session should NOT appear
if echo "$sids" | grep -q "meta3333"; then
  printf '  FAIL: meta-only session meta3333 found in recap\n'
  FAIL=$((FAIL + 1))
else
  printf '  PASS: meta-only session meta3333 filtered out\n'
  PASS=$((PASS + 1))
fi

test_summary
