#!/usr/bin/env bash
# tests/test-gate-agentpager.sh — gate loop x agentpager interactive backend (#91)
# The gate's SPAWN SEAM can route the worker through the agentpager interactive
# channel (backend: agentpager) and still verify+retry against ground truth. The
# live tmux+daemon loop is E2E (AC6 smoke); here the daemon is mocked via the
# session-alive / stop-file / launch-file seams, so the wait + gate + retry logic
# is driven deterministically.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-agentpager-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

RS=$'\x1e'; US=$'\x1f'
# Fast waits so the mocked completion loop does not sleep on real defaults.
export CCS_DISPATCH_AGENTPAGER_STARTUP=3 CCS_DISPATCH_AGENTPAGER_POLL=1 \
       CCS_DISPATCH_AGENTPAGER_STOP_WAIT=2 CCS_DISPATCH_AGENTPAGER_SETTLE=1 \
       CCS_DISPATCH_AGENTPAGER_SETTLE_QUIET=1

WORK="$SCRIPT_DIR/tmp/test-gate-agentpager"; rm -rf "$WORK"
mkdir -p "$WORK/repo"; _TEST_DIRS+=("$WORK")

# ── schema: backend enum ────────────────────────────────────────────────────
echo "=== schema accepts backend: agentpager ==="
cat > "$WORK/ok.yaml" <<YAML
id: t
goal: g
backend: agentpager
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    verify: { cmd: "true" }
YAML
_ccs_dispatch_gate_load_task "$WORK/ok.yaml" >/dev/null 2>&1
assert_eq "backend agentpager valid" "0" "$?"

echo "=== schema accepts omitted backend (headless default) ==="
cat > "$WORK/plain.yaml" <<YAML
id: t
goal: g
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    verify: { cmd: "true" }
YAML
_ccs_dispatch_gate_load_task "$WORK/plain.yaml" >/dev/null 2>&1
assert_eq "omitted backend valid" "0" "$?"

echo "=== schema rejects bogus backend value ==="
cat > "$WORK/bogus.yaml" <<YAML
id: t
goal: g
backend: sideways
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    verify: { cmd: "true" }
YAML
_ccs_dispatch_gate_load_task "$WORK/bogus.yaml" >/dev/null 2>&1
assert_eq "bogus backend rejected" "1" "$?"

echo "=== schema rejects backend: agentpager + executor: wingman ==="
cat > "$WORK/apwing.yaml" <<YAML
id: t
goal: g
backend: agentpager
executor: wingman
plan: p.md
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    verify: { cmd: "true" }
YAML
_ccs_dispatch_gate_load_task "$WORK/apwing.yaml" >/dev/null 2>&1
assert_eq "agentpager+wingman rejected" "1" "$?"

# ── foreground wait helper ──────────────────────────────────────────────────
echo "=== wait_and_collect: handoff appears -> rc 0, seat reclaimed, output collected ==="
SEAT="$WORK/seat"; : > "$SEAT"
_ccs_dispatch_agentpager_session_alive() { [ -f "$SEAT" ]; }
_ccs_dispatch_agentpager_stop_file() { rm -f "$SEAT"; echo "$WORK/stopfile"; }
hs="$WORK/repo/tmp/handoff-sig1.md"; mkdir -p "$WORK/repo/tmp"
printf -- '---\nsummary: did it\noutcome: done\n---\n' > "$hs"
strm="$WORK/out.stream"
printf '%sMSG%sprose%s\ndone task\n%sEND%s\n' "$RS" "$US" "$RS" "$RS" "$RS" > "$strm"
dest="$WORK/out.md"
_ccs_dispatch_agentpager_wait_and_collect "local-tester" "$WORK/pager" "$hs" "sig1" "$strm" 0 "$dest" 3 5
rc=$?
assert_eq "wait rc 0 on handoff" "0" "$rc"
assert_eq "seat reclaimed" "no" "$([ -f "$SEAT" ] && echo yes || echo no)"
assert_contains "collected this-job output" "$(cat "$dest")" "done task"

echo "=== wait_and_collect: no handoff -> bounded timeout rc 1, seat reclaimed ==="
: > "$SEAT"
_ccs_dispatch_agentpager_wait_and_collect "local-tester" "$WORK/pager" "$WORK/nope.md" "sigT" "$strm" 0 "$WORK/o2.md" 2 1
rc=$?
assert_eq "wait rc 1 on timeout" "1" "$rc"
assert_eq "seat reclaimed on timeout" "no" "$([ -f "$SEAT" ] && echo yes || echo no)"
unset -f _ccs_dispatch_agentpager_session_alive _ccs_dispatch_agentpager_stop_file

# ── integration: run_one drives the agentpager branch through the gate ───────
export CCS_DISPATCH_PROJ_MAP="$WORK/proj-map"
printf 'apkey=%s\n' "$WORK/repo" > "$CCS_DISPATCH_PROJ_MAP"
export AGENT_PAGER_DIR="$WORK/pager"   # sandbox: no real state json / stream leaks in
_ccs_dispatch_agentpager_available() { return 0; }   # mock: daemon "up"
LAUNCHLOG="$WORK/launchlog"

echo "=== integration: backend=agentpager, worker makes target -> gate PASS ==="
cat > "$WORK/pass.yaml" <<YAML
id: gp
goal: "make x"
backend: agentpager
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    text: "x exists"
    verify: { cmd: "test -f x.txt" }
YAML
: > "$LAUNCHLOG"; rm -f "$WORK/seat" "$WORK/repo/x.txt"; rm -f "$WORK/repo/tmp"/handoff-*.md
_ccs_dispatch_agentpager_session_alive() { [ -f "$WORK/seat" ]; }
_ccs_dispatch_agentpager_stop_file() { rm -f "$WORK/seat"; echo "$WORK/stop"; }
_ccs_dispatch_agentpager_launch_file() {   # mock the daemon: worker makes target + handoff
  local sig="$1"; local prompt="$4"
  mkdir -p "$WORK/repo/tmp"; : > "$WORK/seat"; : > "$WORK/repo/x.txt"
  printf -- '---\nsummary: s\noutcome: done\n---\n' > "$WORK/repo/tmp/handoff-${sig}.md"
  echo "$sig" >> "$LAUNCHLOG"; echo "$WORK/inbound-${sig}"
}
task_json="$(_ccs_dispatch_gate_load_task "$WORK/pass.yaml")"
hop="$WORK/hop-pass"; rm -rf "$hop"
term="$(_ccs_dispatch_run_one "$task_json" "$WORK/pass.yaml" "$hop")"; rc=$?
assert_eq "PASS term" "PASS" "$term"
assert_eq "PASS rc 0" "0" "$rc"
assert_eq "PASS outcome" "accepted" "$(jq -r '.outcome' "$hop/final.json")"

echo "=== integration: attempt1 FAIL -> retry -> attempt2 PASS (Option B) ==="
cat > "$WORK/retry.yaml" <<YAML
id: gr
goal: "make y"
backend: agentpager
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    text: "y exists"
    verify: { cmd: "test -f y.txt" }
YAML
: > "$LAUNCHLOG"; rm -f "$WORK/seat" "$WORK/repo/y.txt"; rm -f "$WORK/repo/tmp"/handoff-*.md
_ccs_dispatch_agentpager_launch_file() {   # only attempt>=2 (feedback-prefixed) makes the target
  local sig="$1"; local prompt="$4"
  mkdir -p "$WORK/repo/tmp"; : > "$WORK/seat"
  case "$prompt" in *"未通過驗收"*) : > "$WORK/repo/y.txt" ;; esac
  printf -- '---\nsummary: s\noutcome: done\n---\n' > "$WORK/repo/tmp/handoff-${sig}.md"
  echo "$sig" >> "$LAUNCHLOG"; echo "$WORK/inbound-${sig}"
}
hop2="$WORK/hop-retry"; rm -rf "$hop2"
term2="$(_ccs_dispatch_run_one "$(_ccs_dispatch_gate_load_task "$WORK/retry.yaml")" "$WORK/retry.yaml" "$hop2")"; rc2=$?
assert_eq "retry then PASS term" "PASS" "$term2"
assert_eq "retry PASS rc 0" "0" "$rc2"
assert_eq "took 2 attempts" "2" "$(jq -r '.attempts' "$hop2/final.json")"
# per-attempt handoff files do not collide (distinct sigs)
assert_eq "two distinct launches" "2" "$(sort -u "$LAUNCHLOG" | wc -l | tr -d ' ')"
assert_eq "two per-attempt handoff files" "2" \
  "$(ls "$WORK/repo/tmp"/handoff-*.md 2>/dev/null | wc -l | tr -d ' ')"
echo "=== integration: daemon unavailable -> fast-fail -> ESCALATE ==="
cat > "$WORK/down.yaml" <<YAML
id: gd
goal: "make z"
backend: agentpager
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    text: "z exists"
    verify: { cmd: "test -f z.txt" }
YAML
rm -f "$WORK/repo/z.txt"
_ccs_dispatch_agentpager_available() { return 1; }   # daemon down -> fast-fail
hop3="$WORK/hop-down"; rm -rf "$hop3"
term3="$(_ccs_dispatch_run_one "$(_ccs_dispatch_gate_load_task "$WORK/down.yaml")" "$WORK/down.yaml" "$hop3")"; rc3=$?
assert_eq "daemon-down term ESCALATE" "ESCALATE" "$term3"
assert_eq "daemon-down rc 10" "10" "$rc3"
assert_eq "fast-fail error recorded" "yes" \
  "$([ -f "$hop3/attempt-01/agentpager-error.txt" ] && echo yes || echo no)"

unset -f _ccs_dispatch_agentpager_session_alive _ccs_dispatch_agentpager_stop_file \
         _ccs_dispatch_agentpager_launch_file _ccs_dispatch_agentpager_available

test_summary
