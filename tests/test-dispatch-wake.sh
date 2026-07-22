#!/usr/bin/env bash
# tests/test-dispatch-wake.sh — orchestrator-wake (#93)
# Units: _ccs_dispatch_resolve_wake_slot (env -> slot, CCS_DISPATCH_WAKE opt-out),
#   _ccs_dispatch_agentpager_wake_file (atomic kind:input inbound writer),
#   finish-hook integration (non-chain wakes; chain hop does NOT),
#   chain-notify integration (chain end wakes).
# Isolation: XDG_DATA_HOME sandbox; AGENT_PAGER_DIR points at a sandbox inbound;
#   the Telegram notify path is suppressed (CCS_DISPATCH_NOTIFY=0) to isolate wake.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-wake-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

DD="$(_ccs_dispatch_dir)"
JOBS="$DD/jobs.jsonl"
SANDBOX="$SCRIPT_DIR/tmp/test-dispatch-wake"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
PAGER_DIR="$SANDBOX/pager"

reset_case() {
  rm -f "$JOBS"; rm -rf "$DD/results" "$DD/pids" "$PAGER_DIR"
  mkdir -p "$DD/results" "$DD/pids" "$PAGER_DIR/inbound"
  unset AGENT_PAGER_SESSION_TREE AGENT_PAGER_BOT_SLOT AGENT_PAGER_CHANNEL \
    AGENT_PAGER_LOCAL_USER CCS_DISPATCH_WAKE 2>/dev/null || true
  export CCS_DISPATCH_NOTIFY=0        # isolate wake from the Telegram notify path
  export AGENT_PAGER_DIR="$PAGER_DIR" # wake writer resolves inbound dir from here
}

# Seed one agentpager job record (+ optional handoff source file).
seed_job_wake() { # $1=job_id $2=wake_slot(empty=none) $3=chain(empty|true) $4=with_handoff(0|1)
  local jid="$1" ws="$2" ch="$3" wh="$4"
  local rec="{\"job_id\":\"$jid\",\"project\":\"proj-x\",\"backend\":\"agentpager\",\"status\":\"running\",\"created_at\":\"2026-07-07T10:00:00+08:00\""
  [ -n "$ws" ] && rec="$rec,\"wake_slot\":\"$ws\""
  [ "$ch" = "true" ] && rec="$rec,\"chain\":true"
  rec="$rec}"
  printf '%s\n' "$rec" >> "$JOBS"
  HANDOFF_SRC="$SANDBOX/handoff-$jid.md"; rm -f "$HANDOFF_SRC"
  [ "$wh" = 1 ] && printf '# handoff\n' > "$HANDOFF_SRC"
}

wake_files() { ls "$PAGER_DIR/inbound"/*-wake.md 2>/dev/null; }
wake_count() { wake_files | wc -l | tr -d ' '; }
latest_wake() { ls -t "$PAGER_DIR/inbound"/*-wake.md 2>/dev/null | head -1; }
wake_field() { sed -n "s/^$2: //p" "$1" | head -1; }          # $1=file $2=field
wake_body()  { awk 'f>=2{print; next} /^---$/{f++}' "$1"; }   # $1=file

# ── AC1/AC2/AC3: _ccs_dispatch_resolve_wake_slot ────────────────────────────
echo "=== resolve: telegram numeric slot (AC1) ==="
reset_case
export AGENT_PAGER_SESSION_TREE="slot-3" AGENT_PAGER_BOT_SLOT="3"
assert_eq "numeric slot resolves to N" "3" "$(_ccs_dispatch_resolve_wake_slot)"

echo "=== resolve: local channel slot (AC1) ==="
reset_case
export AGENT_PAGER_SESSION_TREE="local-alice" AGENT_PAGER_CHANNEL="local" \
  AGENT_PAGER_LOCAL_USER="alice"
assert_eq "local channel resolves to local-<user>" "local-alice" \
  "$(_ccs_dispatch_resolve_wake_slot)"

echo "=== resolve: local precedence over a stray numeric slot (AC1) ==="
reset_case
export AGENT_PAGER_SESSION_TREE="local-bob" AGENT_PAGER_CHANNEL="local" \
  AGENT_PAGER_LOCAL_USER="bob" AGENT_PAGER_BOT_SLOT="9"
assert_eq "local channel wins over numeric" "local-bob" \
  "$(_ccs_dispatch_resolve_wake_slot)"

echo "=== resolve: no pager env -> empty (AC2, case b) ==="
reset_case
assert_eq "no env -> empty" "" "$(_ccs_dispatch_resolve_wake_slot)"

echo "=== resolve: CCS_DISPATCH_WAKE=0 opts out (AC3) ==="
reset_case
export AGENT_PAGER_SESSION_TREE="slot-3" AGENT_PAGER_BOT_SLOT="3" CCS_DISPATCH_WAKE=0
assert_eq "opt-out -> empty even with env" "" "$(_ccs_dispatch_resolve_wake_slot)"

echo "=== resolve: local channel with empty user falls through to numeric (N3) ==="
reset_case
export AGENT_PAGER_SESSION_TREE="slot-7" AGENT_PAGER_CHANNEL="local" AGENT_PAGER_BOT_SLOT="7"
# AGENT_PAGER_LOCAL_USER intentionally unset -> local branch must not fire
assert_eq "empty local user -> fall through to numeric slot" "7" \
  "$(_ccs_dispatch_resolve_wake_slot)"

# ── AC4 writer unit: _ccs_dispatch_agentpager_wake_file ─────────────────────
echo "=== wake writer: atomic kind:input inbound (AC4) ==="
reset_case
wf="$(_ccs_dispatch_agentpager_wake_file "3" "$PAGER_DIR" $'first line\nsecond line')"
assert_eq "wake file created" "yes" "$([ -n "$wf" ] && [ -f "$wf" ] && echo yes)"
assert_eq "kind is input" "input" "$(wake_field "$wf" kind)"
assert_eq "slot is the target" "3" "$(wake_field "$wf" slot)"
assert_contains "body carried" "$(wake_body "$wf")" "first line"
assert_eq "filename matches the *.md glob" "yes" \
  "$(case "$wf" in *.md) echo yes;; *) echo no;; esac)"
assert_eq "no leftover .tmp dotfile" "0" \
  "$(find "$PAGER_DIR/inbound" -name '.*.tmp' 2>/dev/null | wc -l | tr -d ' ')"

# ── AC4 integration: finish (non-chain) fires wake ──────────────────────────
echo "=== finish non-chain: wake inbound written, thin pointer (AC4) ==="
reset_case
seed_job_wake "w-nc" "3" "" 1
_ccs_dispatch_finish_agentpager "w-nc" "$HANDOFF_SRC"
wf="$(latest_wake)"
assert_eq "non-chain finalize wrote one wake" "1" "$(wake_count)"
assert_eq "wake kind input" "input" "$(wake_field "$wf" kind)"
assert_eq "wake slot 3" "3" "$(wake_field "$wf" slot)"
assert_contains "body names the job" "$(wake_body "$wf")" "w-nc"
assert_contains "body carries status" "$(wake_body "$wf")" "handoff-ready"
assert_contains "body points to the on-disk artifact" "$(wake_body "$wf")" "results/w-nc.md"

# ── AC2 integration: no wake_slot -> no wake (case b path) ───────────────────
echo "=== finish: no wake_slot -> no wake (AC2) ==="
reset_case
seed_job_wake "w-none" "" "" 1
_ccs_dispatch_finish_agentpager "w-none" "$HANDOFF_SRC"
assert_eq "no wake_slot -> zero wake inbounds" "0" "$(wake_count)"

# ── AC3 integration: finalize honors opt-out even if a slot is present ───────
echo "=== finish: CCS_DISPATCH_WAKE=0 suppresses wake (AC3) ==="
reset_case
export CCS_DISPATCH_WAKE=0
seed_job_wake "w-off" "3" "" 1
_ccs_dispatch_finish_agentpager "w-off" "$HANDOFF_SRC"
assert_eq "opt-out at finalize -> zero wake inbounds" "0" "$(wake_count)"

# ── AC5 status-agnostic: handoff-ready / completed / failed ──────────────────
echo "=== finish status-agnostic: handoff-ready (AC5) ==="
reset_case; seed_job_wake "w-hr" "3" "" 1
_ccs_dispatch_finish_agentpager "w-hr" "$HANDOFF_SRC"
assert_contains "payload carries handoff-ready" "$(wake_body "$(latest_wake)")" "handoff-ready"

echo "=== finish status-agnostic: completed (AC5) ==="
reset_case; seed_job_wake "w-cp" "3" "" 0
_ccs_dispatch_finish_agentpager "w-cp" "$SANDBOX/nonexistent-handoff"
assert_contains "payload carries completed" "$(wake_body "$(latest_wake)")" "completed"

echo "=== finish status-agnostic: failed (AC5) ==="
reset_case; seed_job_wake "w-fl" "3" "" 0
_ccs_dispatch_finish_agentpager "w-fl" "$SANDBOX/nonexistent-handoff" "failed"
assert_contains "payload carries failed" "$(wake_body "$(latest_wake)")" "failed"

# ── AC5b chain semantics: intermediate hop silent, chain end wakes ──────────
echo "=== chain hop finalize does NOT wake (AC5b, item 11) ==="
reset_case
seed_job_wake "w-chop" "3" "true" 1
_ccs_dispatch_finish_agentpager "w-chop" "$HANDOFF_SRC"
assert_eq "chain intermediate hop stays silent" "0" "$(wake_count)"

echo "=== chain end wakes once, with artifact when it exists (AC5b) ==="
reset_case
seed_job_wake "w-cend" "3" "true" 1
printf '# result\n' > "$DD/results/w-cend.md"   # terminal hop produced an artifact
_ccs_dispatch_chain_notify "w-cend" "empty-next" "proj-x" 2
wf="$(latest_wake)"
assert_eq "chain end wrote one wake" "1" "$(wake_count)"
assert_eq "chain-end wake slot 3" "3" "$(wake_field "$wf" slot)"
assert_contains "chain-end body mentions chain" "$(wake_body "$wf")" "chain"
assert_contains "chain-end body names the last job" "$(wake_body "$wf")" "w-cend"
assert_contains "chain-end body points to the existing artifact" \
  "$(wake_body "$wf")" "results/w-cend.md"

echo "=== chain end omits a dangling artifact when the md is absent (M1) ==="
reset_case
seed_job_wake "w-cfail" "3" "true" 0        # launch-failed terminal hop: no results md
_ccs_dispatch_chain_notify "w-cfail" "failed" "proj-x" 3
wf="$(latest_wake)"
assert_eq "chain end still wakes on a launch-failed hop" "1" "$(wake_count)"
assert_not_contains "no dangling artifact pointer" "$(wake_body "$wf")" "results/w-cfail.md"
assert_contains "failure signal still names the last job" "$(wake_body "$wf")" "w-cfail"

echo "=== chain-end wake_slot survives jsonl reduce-merge (M2) ==="
reset_case
seed_job_wake "w-cmerge" "3" "true" 1
printf '# result\n' > "$DD/results/w-cmerge.md"
# a later chain_stopped record carries no wake_slot; reduce-merge keeps absent
# keys, so the creation record's wake_slot must still drive the wake.
printf '%s\n' '{"job_id":"w-cmerge","chain_stopped":"empty-next"}' >> "$JOBS"
_ccs_dispatch_chain_notify "w-cmerge" "empty-next" "proj-x" 2
assert_eq "wake_slot survives merge with a later chain_stopped record" "1" "$(wake_count)"
assert_eq "merged wake targets the captured slot" "3" "$(wake_field "$(latest_wake)" slot)"

echo "=== chain end without wake_slot stays silent (AC2/AC5b) ==="
reset_case
seed_job_wake "w-cend2" "" "true" 1
_ccs_dispatch_chain_notify "w-cend2" "depth" "proj-x" 5
assert_eq "chain end without wake_slot -> no wake" "0" "$(wake_count)"

test_summary
