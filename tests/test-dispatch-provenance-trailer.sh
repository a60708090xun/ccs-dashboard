#!/usr/bin/env bash
# tests/test-dispatch-provenance-trailer.sh — ccs-dispatch-run suggests an
# advisory X-Executor: provenance trailer at completion (executor + optional
# model from task.yaml; graceful fallback to executor-only).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-provenance-trailer-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-provenance-trailer"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

CWD="$WORK/repo"; mkdir -p "$CWD"; (cd "$CWD" && git init -q)

# Mock worker: satisfy the AC (create done.txt); executor/model are read by the
# chain driver from the task, not the worker, so args are irrelevant here.
_ccs_dispatch_run_worker() {
  local run_dir="$3" attempt="$4"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"
  : > "$CWD/done.txt"
  return 0
}

# mk <file> [extra-top-level-yaml-line ...] -- build a task.yaml, echo its path.
mk() {
  local f="$WORK/$1"; shift
  { echo "id: t"; echo "goal: g";
    local line; for line in "$@"; do echo "$line"; done
    echo "scope: {cwd: \"$CWD\"}";
    echo "acceptance_criteria:";
    echo "  - id: AC1";
    echo "    text: t";
    echo "    verify: {cmd: \"test -f $CWD/done.txt\"}"; } > "$f"
  echo "$f"
}

echo "=== executor + model -> executor/model trailer ==="
rm -f "$CWD/done.txt"
out="$(ccs-dispatch-run "$(mk gm.yaml 'executor: gemini' 'model: gemini-2.5-pro')" 2>/dev/null)"
assert_contains "trailer carries executor/model" "$out" \
  "X-Executor: gemini/gemini-2.5-pro (ccs-dispatch-run)"

echo "=== executor, no model -> executor-only trailer (no dangling slash) ==="
rm -f "$CWD/done.txt"
out="$(ccs-dispatch-run "$(mk g.yaml 'executor: gemini')" 2>/dev/null)"
assert_contains "trailer falls back to executor-only" "$out" \
  "X-Executor: gemini (ccs-dispatch-run)"
assert_not_contains "no dangling slash when model absent" "$out" "gemini/"

echo "=== omitted executor -> defaults to claude ==="
rm -f "$CWD/done.txt"
out="$(ccs-dispatch-run "$(mk n.yaml)" 2>/dev/null)"
assert_contains "trailer defaults executor to claude" "$out" \
  "X-Executor: claude (ccs-dispatch-run)"

echo "=== 2-hop chain, distinct executors -> two distinct trailers ==="
rm -f "$CWD/done.txt"
mk second.yaml 'executor: claude' >/dev/null
out="$(ccs-dispatch-run "$(mk first.yaml 'executor: gemini' 'next: second.yaml')" 2>/dev/null)"
assert_contains "chain trailer for hop-1 executor" "$out" \
  "X-Executor: gemini (ccs-dispatch-run)"
assert_contains "chain trailer for hop-2 executor" "$out" \
  "X-Executor: claude (ccs-dispatch-run)"

echo "=== 2-hop chain, SAME executor -> one collapsed trailer line ==="
rm -f "$CWD/done.txt"
mk s2.yaml 'executor: gemini' >/dev/null
out="$(ccs-dispatch-run "$(mk f2.yaml 'executor: gemini' 'next: s2.yaml')" 2>/dev/null)"
n="$(printf '%s\n' "$out" | grep -cF 'X-Executor: gemini (ccs-dispatch-run)')"
assert_eq "same-executor hops dedup to a single trailer" "1" "$n"

# Escalate path: worker never satisfies the AC (no done.txt) and loop_budget 0
# forces a single-attempt ESCALATE. The trailer must still print (the convention
# covers escalate-then-orchestrator-commits). Redefined mock stays last.
echo "=== escalated outcome still prints trailer ==="
rm -f "$CWD/done.txt"
_ccs_dispatch_run_worker() { mkdir -p "$3/attempt-$(printf '%02d' "$4")"; return 0; }
out="$(ccs-dispatch-run "$(mk esc.yaml 'executor: gemini' 'model: m1' \
  'execution_policy: {loop_budget: 0}')" 2>/dev/null)"
assert_contains "outcome is escalated (AC unsatisfied)" "$out" "outcome: escalated"
assert_contains "trailer prints on escalated outcome" "$out" \
  "X-Executor: gemini/m1 (ccs-dispatch-run)"

test_summary
