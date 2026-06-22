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
test_summary
