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

echo "=== resolve_backend: auto detection (daemon/spool gates) ==="
mock_dir="$SCRIPT_DIR/tmp/test-dispatch-backend-bin"
mkdir -p "$mock_dir"
# daemon inactive (systemctl exit 3) -> headless
printf '#!/bin/bash\nexit 3\n' > "$mock_dir/systemctl"
chmod +x "$mock_dir/systemctl"
out=$(CCS_DISPATCH_BACKEND=auto PATH="$mock_dir:$PATH" _ccs_dispatch_resolve_backend)
assert_eq "auto + daemon inactive -> headless" "headless" "$out"

# daemon active from here on
printf '#!/bin/bash\nexit 0\n' > "$mock_dir/systemctl"
chmod +x "$mock_dir/systemctl"

# daemon active but spool dir missing -> headless
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$SCRIPT_DIR/tmp/nonexistent-spool" \
  PATH="$mock_dir:$PATH" _ccs_dispatch_resolve_backend)
assert_eq "auto + active + no spool -> headless" "headless" "$out"

echo "=== resolve_backend: Hybrid Detection — same-uid (personal) ==="
# same-uid: spool owned by the current user + inbound/ present -> agentpager,
# skipping the claude-broker group + setgid checks (design Decision A).
# stat/id are the REAL ones here; the test-created spool is owned by the caller.
spool="$SCRIPT_DIR/tmp/test-dispatch-backend-spool"
mkdir -p "$spool/inbound"
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$spool" PATH="$mock_dir:$PATH" \
  _ccs_dispatch_resolve_backend)
assert_eq "same-uid + active + inbound -> agentpager" "agentpager" "$out"

# same-uid but inbound/ missing -> headless (local channel not initialized)
spool_ni="$SCRIPT_DIR/tmp/test-dispatch-backend-spool-noinbound"
mkdir -p "$spool_ni"
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$spool_ni" PATH="$mock_dir:$PATH" \
  _ccs_dispatch_resolve_backend)
assert_eq "same-uid + active + no inbound -> headless" "headless" "$out"

rm -rf "$mock_dir" "$spool" "$spool_ni"

echo "=== resolve_backend: Hybrid Detection — cross-uid (shared seat) ==="
# Cross-uid path: spool owned by a DIFFERENT user. stat/id are mocked so the
# ownership + broker-group + setgid strict checks run without needing root.
xbin="$SCRIPT_DIR/tmp/test-dispatch-backend-xbin"
mkdir -p "$xbin"
printf '#!/bin/bash\nexit 0\n' > "$xbin/systemctl"
cat > "$xbin/stat" <<'EOF'
#!/bin/bash
# mock: stat -c %u <path>  /  stat -c %G <path>
case "$2" in
  %u) echo "${MOCK_STAT_U:-0}" ;;
  %G) echo "${MOCK_STAT_G:-nogroup}" ;;
  *)  exit 1 ;;
esac
EOF
cat > "$xbin/id" <<'EOF'
#!/bin/bash
case "$1" in
  -u)  echo "${MOCK_ID_U:-1000}" ;;
  -un) echo "${MOCK_ID_UN:-tester}" ;;
  -nG) echo "${MOCK_ID_GROUPS:-tester}" ;;
esac
EOF
chmod +x "$xbin"/*
xspool="$SCRIPT_DIR/tmp/test-dispatch-backend-xspool"
mkdir -p "$xspool/inbound"

# cross-uid (owner 4242 != caller 1000) + caller NOT in claude-broker -> headless
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$xspool" \
  MOCK_STAT_U=4242 MOCK_ID_U=1000 MOCK_ID_UN=tester MOCK_ID_GROUPS="tester users" \
  MOCK_STAT_G=nogroup PATH="$xbin:$PATH" _ccs_dispatch_resolve_backend)
assert_eq "cross-uid + not in broker -> headless" "headless" "$out"

# cross-uid + in claude-broker + inbound setgid to claude-broker -> agentpager
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$xspool" \
  MOCK_STAT_U=4242 MOCK_ID_U=1000 MOCK_ID_UN=tester MOCK_ID_GROUPS="tester claude-broker" \
  MOCK_STAT_G=claude-broker PATH="$xbin:$PATH" _ccs_dispatch_resolve_backend)
assert_eq "cross-uid + broker group + setgid -> agentpager" "agentpager" "$out"

# cross-uid + in claude-broker but inbound NOT setgid claude-broker -> headless
out=$(CCS_DISPATCH_BACKEND=auto AGENT_PAGER_DIR="$xspool" \
  MOCK_STAT_U=4242 MOCK_ID_U=1000 MOCK_ID_UN=tester MOCK_ID_GROUPS="tester claude-broker" \
  MOCK_STAT_G=othergroup PATH="$xbin:$PATH" _ccs_dispatch_resolve_backend)
assert_eq "cross-uid + broker group + no setgid -> headless" "headless" "$out"

rm -rf "$xbin" "$xspool"

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

echo "=== agentpager backend falls back to headless (sync / no proj-map) ==="
mock_dir3="$SCRIPT_DIR/tmp/test-dispatch-backend-bin3"
proj3="$SCRIPT_DIR/tmp/test-dispatch-backend-proj3"
mkdir -p "$mock_dir3" "$proj3"
printf '#!/bin/bash\necho "mock result: $*"\n' > "$mock_dir3/claude"
chmod +x "$mock_dir3/claude"
# force agentpager; --sync (async-only backend) returns 2 -> dispatcher falls back
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
