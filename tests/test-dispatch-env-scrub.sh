#!/usr/bin/env bash
# tests/test-dispatch-env-scrub.sh — headless CLI child must not inherit
# AGENT_PAGER_* from the orchestrator (issue #114). Evidence only goes to
# the attempt / results tree; the child must not run pager hooks as the
# parent slot.
#
# Two production sites share one helper: gate-run headless
# (_ccs_dispatch_run_worker) and job-spawn (_ccs_dispatch_spawn_headless
# sync). The async nohup path uses the same helper; test-dispatch.sh
# covers that it still completes.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-env-scrub-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-env-scrub"
rm -rf "$WORK"; mkdir -p "$WORK/bin" "$WORK/repo" "$WORK/env"
_TEST_DIRS+=("$WORK")
(cd "$WORK/repo" && git init -q)

# Fake CLI dumps the pager namespace + a marker, then exits 0.
# FAKE_ENV_LOG is per-case so parallel-looking sequential cases do not mix.
cat > "$WORK/bin/claude" <<'FAKE'
#!/usr/bin/env bash
{
  printenv CCS_SCRUB_MARKER
  printenv | grep '^AGENT_PAGER_' || true
} > "${FAKE_ENV_LOG:?}"
exit 0
FAKE
chmod +x "$WORK/bin/claude"
cp "$WORK/bin/claude" "$WORK/bin/gemini"
chmod +x "$WORK/bin/gemini"
export PATH="$WORK/bin:$PATH"

export AGENT_PAGER_NOTIFY=1
export AGENT_PAGER_BOT_SLOT=9
export AGENT_PAGER_SESSION_TREE=/x
export CCS_SCRUB_MARKER=keep

assert_parent_intact() {
  assert_eq "parent keeps NOTIFY" "1" "${AGENT_PAGER_NOTIFY}"
  assert_eq "parent keeps BOT_SLOT" "9" "${AGENT_PAGER_BOT_SLOT}"
  assert_eq "parent keeps SESSION_TREE" "/x" "${AGENT_PAGER_SESSION_TREE}"
}

assert_child_scrubbed() {
  local log="$1" label="$2"
  local body
  body="$(cat "$log" 2>/dev/null || true)"
  assert_contains "$label: log is non-empty (marker is the lower bound)" \
    "$body" "keep"
  assert_eq "$label: child has no AGENT_PAGER_*" "" \
    "$(printf '%s\n' "$body" | grep '^AGENT_PAGER_' || true)"
}

echo "=== gate-run headless child does not inherit AGENT_PAGER_* ==="
export FAKE_ENV_LOG="$WORK/env/gate-run.log"
: > "$FAKE_ENV_LOG"
RUN="$WORK/run-gate"; rm -rf "$RUN"; mkdir -p "$RUN"
_ccs_dispatch_run_worker "$WORK/repo" "do X" "$RUN" 1 60 claude
assert_child_scrubbed "$FAKE_ENV_LOG" "gate-run"
assert_parent_intact

echo "=== job-spawn sync child does not inherit AGENT_PAGER_* ==="
export FAKE_ENV_LOG="$WORK/env/job-sync.log"
: > "$FAKE_ENV_LOG"
_ccs_dispatch_spawn_headless "d-scrub-sync" "$WORK/repo" "do Y" 60 sync >/dev/null
assert_child_scrubbed "$FAKE_ENV_LOG" "job-sync"
assert_parent_intact

echo "=== empty AGENT_PAGER_* namespace still spawns ==="
export FAKE_ENV_LOG="$WORK/env/empty.log"
: > "$FAKE_ENV_LOG"
(
  while IFS= read -r v; do unset "$v"; done < <(compgen -v AGENT_PAGER_ || true)
  RUN="$WORK/run-empty"; rm -rf "$RUN"; mkdir -p "$RUN"
  _ccs_dispatch_run_worker "$WORK/repo" "do Z" "$RUN" 1 60 claude
)
body="$(cat "$FAKE_ENV_LOG" 2>/dev/null || true)"
assert_contains "empty-ns: CLI still ran" "$body" "keep"
assert_eq "empty-ns: child has no AGENT_PAGER_*" "" \
  "$(printf '%s\n' "$body" | grep '^AGENT_PAGER_' || true)"
assert_parent_intact

test_summary
