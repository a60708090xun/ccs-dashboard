#!/usr/bin/env bash
# tests/test-dispatch-backend.sh — backend resolver + fallback (stage 1)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

echo "=== resolve_backend: env override ==="
out=$(CCS_DISPATCH_BACKEND=headless _ccs_dispatch_resolve_backend)
assert_eq "explicit headless" "headless" "$out"
out=$(CCS_DISPATCH_BACKEND=agentpager _ccs_dispatch_resolve_backend)
assert_eq "explicit agentpager" "agentpager" "$out"
out=$(CCS_DISPATCH_BACKEND=bogus _ccs_dispatch_resolve_backend)
assert_eq "invalid -> headless" "headless" "$out"

echo "=== resolve_backend: auto detection ==="
mock_dir="$SCRIPT_DIR/tmp/test-dispatch-backend-bin"
mkdir -p "$mock_dir"
# daemon inactive (systemctl exit 3) -> headless
printf '#!/bin/bash\nexit 3\n' > "$mock_dir/systemctl"
chmod +x "$mock_dir/systemctl"
out=$(CCS_DISPATCH_BACKEND=auto PATH="$mock_dir:$PATH" _ccs_dispatch_resolve_backend)
assert_eq "auto + daemon inactive -> headless" "headless" "$out"

# daemon active + spool dir exists -> agentpager
printf '#!/bin/bash\nexit 0\n' > "$mock_dir/systemctl"
chmod +x "$mock_dir/systemctl"
spool="$SCRIPT_DIR/tmp/test-dispatch-backend-spool"
mkdir -p "$spool"
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$spool" PATH="$mock_dir:$PATH" \
  _ccs_dispatch_resolve_backend)
assert_eq "auto + active + spool -> agentpager" "agentpager" "$out"

# daemon active but spool missing -> headless
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$SCRIPT_DIR/tmp/nonexistent-spool" \
  PATH="$mock_dir:$PATH" _ccs_dispatch_resolve_backend)
assert_eq "auto + active + no spool -> headless" "headless" "$out"

rm -rf "$mock_dir" "$spool"

echo "=== dispatcher routes to headless (behavior unchanged) ==="
mock_dir2="$SCRIPT_DIR/tmp/test-dispatch-backend-bin2"
proj="$SCRIPT_DIR/tmp/test-dispatch-backend-proj"
mkdir -p "$mock_dir2" "$proj"
printf '#!/bin/bash\necho "mock result: $*"\n' > "$mock_dir2/claude"
chmod +x "$mock_dir2/claude"
# force headless; dispatcher must produce a completed .md exactly like before
out=$(CCS_DISPATCH_BACKEND=headless PATH="$mock_dir2:$PATH" \
  ccs-dispatch --sync --project "$proj" "route test" 2>&1)
jid=$(echo "$out" | grep -oP 'd-\d{8}-\d{6}-[a-f0-9]{4}' | head -1)
dd="$(_ccs_dispatch_dir)"
assert_contains "headless dispatch created .md" "$(ls "$dd/results/" 2>/dev/null)" "${jid}.md"
st=$(_ccs_dispatch_jsonl_latest "$jid" | jq -r '.status')
assert_eq "headless dispatch completed" "completed" "$st"
# function-level: headless helper exists and is what dispatcher calls
assert_eq "spawn_headless defined" "function" "$(type -t _ccs_dispatch_spawn_headless)"
rm -rf "$mock_dir2" "$proj"

test_summary
