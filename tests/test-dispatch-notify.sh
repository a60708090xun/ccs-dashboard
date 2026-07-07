#!/usr/bin/env bash
# tests/test-dispatch-notify.sh — agentpager job completion notification (#74)
# Units: sender resolver (env / systemd-derived / none), CCS_DISPATCH_NOTIFY
# gate, finish-hook integration (handoff-ready / failed), best-effort
# degradation when no sender is available.
# Isolation: XDG_DATA_HOME sandbox; sender stubbed by a capture script;
# systemctl stubbed by a shell function.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-notify-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

DD="$(_ccs_dispatch_dir)"
JOBS="$DD/jobs.jsonl"
SANDBOX="$SCRIPT_DIR/tmp/test-dispatch-notify"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"

CAPTURE="$SANDBOX/notify-capture.txt"

# Stub sender: records argv, the AGENT_PAGER_NOTIFY opt-in, and the stdin body.
STUB_SENDER="$SANDBOX/notify-send.sh"
cat > "$STUB_SENDER" <<STUB
#!/usr/bin/env bash
{
  echo "ARGS:\$*"
  echo "OPTIN:\${AGENT_PAGER_NOTIFY:-unset}"
  echo "SLOT:\${AGENT_PAGER_BOT_SLOT:-unset}"
  cat
} >> "$CAPTURE"
exit 0
STUB
chmod +x "$STUB_SENDER"

reset_case() {
  rm -f "$JOBS" "$CAPTURE"; rm -rf "$DD/results" "$DD/pids"
  mkdir -p "$DD/results" "$DD/pids"
  unset AGENT_PAGER_SENDER CCS_DISPATCH_NOTIFY CCS_DISPATCH_NOTIFY_TIMEOUT \
    CCS_DISPATCH_NOTIFY_SLOT 2>/dev/null || true
}

# Seed one agentpager job record + optional handoff source file.
seed_job() { # $1=job_id $2=with_handoff(0/1)
  local jid="$1" with_handoff="$2"
  printf '%s\n' "{\"job_id\":\"$jid\",\"project\":\"proj-x\",\"backend\":\"agentpager\",\"status\":\"running\",\"created_at\":\"2026-07-07T10:00:00+08:00\"}" >> "$JOBS"
  HANDOFF_SRC="$SANDBOX/handoff-$jid.md"
  rm -f "$HANDOFF_SRC"
  [ "$with_handoff" = 1 ] && printf '# handoff\n' > "$HANDOFF_SRC"
}

echo "=== resolver: AGENT_PAGER_SENDER wins when executable ==="
reset_case
export AGENT_PAGER_SENDER="$STUB_SENDER"
assert_eq "resolver honors AGENT_PAGER_SENDER" "$STUB_SENDER" \
  "$(_ccs_dispatch_notify_sender)"

echo "=== resolver: non-executable AGENT_PAGER_SENDER is ignored ==="
reset_case
export AGENT_PAGER_SENDER="$SANDBOX/not-executable.sh"
touch "$SANDBOX/not-executable.sh"
systemctl() { return 1; }
assert_eq "non-executable sender -> empty" "" "$(_ccs_dispatch_notify_sender)"
unset -f systemctl

echo "=== resolver: derives from the runner unit's ExecStart path ==="
reset_case
systemctl() {
  echo "ExecStart={ path=$SANDBOX/inbound-handler.sh ; argv[]=$SANDBOX/inbound-handler.sh ; ignore_errors=no }"
}
assert_eq "systemd-derived sibling notify-send.sh" "$STUB_SENDER" \
  "$(_ccs_dispatch_notify_sender)"
unset -f systemctl

echo "=== resolver: nothing available -> empty ==="
reset_case
systemctl() { return 1; }
assert_eq "no env, no unit -> empty" "" "$(_ccs_dispatch_notify_sender)"
unset -f systemctl

echo "=== finish: handoff-ready notifies with id/status/project/handoff ==="
reset_case
export AGENT_PAGER_SENDER="$STUB_SENDER"
seed_job "n-hr" 1
_ccs_dispatch_finish_agentpager "n-hr" "$HANDOFF_SRC"
body="$(cat "$CAPTURE" 2>/dev/null)"
assert_contains "notify names the job and status" "$body" "n-hr handoff-ready"
assert_not_contains "body carries no label prefix (the sender prepends it)" \
  "$body" "[ccs-dispatch] n-hr"
assert_contains "notify names the project" "$body" "project: proj-x"
assert_contains "notify carries the captured handoff path" "$body" "results/n-hr.handoff"
assert_contains "notify overrides the label" "$body" "--label ccs-dispatch"
assert_contains "sender is opted in for this call" "$body" "OPTIN:1"
assert_contains "default notify slot is 1" "$body" "SLOT:1"

echo "=== slot: CCS_DISPATCH_NOTIFY_SLOT pins the pager bot ==="
reset_case
export AGENT_PAGER_SENDER="$STUB_SENDER"
export CCS_DISPATCH_NOTIFY_SLOT=2
seed_job "n-slot" 1
_ccs_dispatch_finish_agentpager "n-slot" "$HANDOFF_SRC"
assert_contains "notify goes out on the configured slot" \
  "$(cat "$CAPTURE" 2>/dev/null)" "SLOT:2"

echo "=== finish: failed job notifies the failure ==="
reset_case
export AGENT_PAGER_SENDER="$STUB_SENDER"
seed_job "n-fail" 0
_ccs_dispatch_finish_agentpager "n-fail" "$HANDOFF_SRC" "failed"
body="$(cat "$CAPTURE" 2>/dev/null)"
assert_contains "failed status reaches the pager" "$body" "n-fail failed"
assert_not_contains "no handoff line without a handoff" "$body" "handoff:"

echo "=== gate: CCS_DISPATCH_NOTIFY=0 suppresses the call ==="
reset_case
export AGENT_PAGER_SENDER="$STUB_SENDER"
export CCS_DISPATCH_NOTIFY=0
seed_job "n-off" 1
_ccs_dispatch_finish_agentpager "n-off" "$HANDOFF_SRC"
assert_eq "opt-out -> sender never called" "" "$(cat "$CAPTURE" 2>/dev/null)"
assert_eq "finalize still lands handoff-ready" "handoff-ready" \
  "$(_ccs_dispatch_jsonl_latest "n-off" | jq -r '.status')"

echo "=== best-effort: missing sender leaves finalize intact ==="
reset_case
export AGENT_PAGER_SENDER="$SANDBOX/gone.sh"   # does not exist
systemctl() { return 1; }
seed_job "n-nosender" 1
_ccs_dispatch_finish_agentpager "n-nosender" "$HANDOFF_SRC"
unset -f systemctl
rec="$(_ccs_dispatch_jsonl_latest "n-nosender")"
assert_eq "status unaffected by missing sender" "handoff-ready" \
  "$(echo "$rec" | jq -r '.status')"
assert_eq "md still written" "1" \
  "$([ -f "$DD/results/n-nosender.md" ] && echo 1 || echo 0)"

echo "=== best-effort: hanging sender is cut by the timeout ==="
reset_case
HANG_SENDER="$SANDBOX/hang-sender.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$HANG_SENDER"
chmod +x "$HANG_SENDER"
export AGENT_PAGER_SENDER="$HANG_SENDER"
export CCS_DISPATCH_NOTIFY_TIMEOUT=1
seed_job "n-hang" 1
start_s=$(date +%s)
_ccs_dispatch_finish_agentpager "n-hang" "$HANDOFF_SRC"
elapsed=$(( $(date +%s) - start_s ))
assert_eq "finalize lands despite the hanging sender" "handoff-ready" \
  "$(_ccs_dispatch_jsonl_latest "n-hang" | jq -r '.status')"
if [ "$elapsed" -le 5 ]; then
  assert_eq "timeout cuts the hang (took ${elapsed}s)" "ok" "ok"
else
  assert_eq "timeout cuts the hang (took ${elapsed}s)" "ok" "hung"
fi

echo "=== body stays short (mobile-readable) ==="
reset_case
export AGENT_PAGER_SENDER="$STUB_SENDER"
seed_job "n-short" 1
_ccs_dispatch_finish_agentpager "n-short" "$HANDOFF_SRC" "completed" "some operator note"
lines="$(grep -c '' "$CAPTURE" 2>/dev/null || echo 0)"; lines="${lines:-0}"
# capture = ARGS + OPTIN + body; body itself must stay <= 6 lines
if [ "$lines" -le 8 ]; then
  assert_eq "notification body <= 6 lines" "ok" "ok"
else
  assert_eq "notification body <= 6 lines (got $((lines - 2)))" "ok" "too-long"
fi

test_summary
