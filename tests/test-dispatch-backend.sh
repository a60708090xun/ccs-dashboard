#!/usr/bin/env bash
# tests/test-dispatch-backend.sh — backend resolver + fallback (stage 1)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

# Initialize backend tracking variable
_CCS_DISPATCH_LAST_BACKEND=""

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

echo "=== agentpager backend stub falls back to headless ==="
mock_dir3="$SCRIPT_DIR/tmp/test-dispatch-backend-bin3"
proj3="$SCRIPT_DIR/tmp/test-dispatch-backend-proj3"
mkdir -p "$mock_dir3" "$proj3"
printf '#!/bin/bash\necho "mock result: $*"\n' > "$mock_dir3/claude"
chmod +x "$mock_dir3/claude"
# force agentpager; stub fails -> dispatcher falls back to headless
# Capture stderr/stdout to temp file to avoid subshell (which loses variable assignments)
tmplog="$SCRIPT_DIR/tmp/test-dispatch-backend-log3"
CCS_DISPATCH_BACKEND=agentpager PATH="$mock_dir3:$PATH" \
  ccs-dispatch --sync --project "$proj3" "fallback test" \
  >"$tmplog.out" 2>"$tmplog.err"
err=$(cat "$tmplog.err")
assert_contains "fallback warning emitted" "$err" "falling back to headless"
# backend tracking reflects the fallback
assert_eq "LAST_BACKEND reflects fallback" "headless" "$_CCS_DISPATCH_LAST_BACKEND"
# job still completes via headless
out_file="$SCRIPT_DIR/tmp/test-dispatch-backend-out3"
CCS_DISPATCH_BACKEND=agentpager PATH="$mock_dir3:$PATH" \
  ccs-dispatch --sync --project "$proj3" "fallback test 2" > "$out_file" 2>/dev/null
jid=$(grep -oP 'd-\d{8}-\d{6}-[a-f0-9]{4}' "$out_file" | head -1)
st=$(_ccs_dispatch_jsonl_latest "$jid" | jq -r '.status')
assert_eq "fell-back job completed" "completed" "$st"
assert_eq "LAST_BACKEND reflects fallback" "headless" "$_CCS_DISPATCH_LAST_BACKEND"
rm -rf "$mock_dir3" "$proj3" "$tmplog"* "$out_file"

echo "=== jobs record + display backend ==="
mock_dir4="$SCRIPT_DIR/tmp/test-dispatch-backend-bin4"
proj4="$SCRIPT_DIR/tmp/test-dispatch-backend-proj4"
mkdir -p "$mock_dir4" "$proj4"
printf '#!/bin/bash\necho "mock result: $*"\n' > "$mock_dir4/claude"
chmod +x "$mock_dir4/claude"
jid=$(CCS_DISPATCH_BACKEND=headless PATH="$mock_dir4:$PATH" \
  ccs-dispatch --sync --project "$proj4" "backend field test" 2>/dev/null \
  | grep -oP 'd-\d{8}-\d{6}-[a-f0-9]{4}' | head -1)
dd="$(_ccs_dispatch_dir)"
# merged record carries backend (initial record) + status (finish record)
merged=$(grep "\"job_id\":\"$jid\"" "$dd/jobs.jsonl" \
  | jq -s 'reduce .[] as $r ({}; . + $r)')
assert_eq "jsonl backend recorded" "headless" "$(echo "$merged" | jq -r '.backend')"
assert_eq "jsonl status preserved" "completed" "$(echo "$merged" | jq -r '.status')"
# .md shows backend
assert_contains ".md shows backend" "$(cat "$dd/results/${jid}.md")" "Backend:"
# list shows backend column
assert_contains "ccs-jobs list shows backend" "$(ccs-jobs 2>/dev/null)" "headless"
rm -rf "$mock_dir4" "$proj4"

test_summary
