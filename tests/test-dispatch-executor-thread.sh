#!/usr/bin/env bash
# tests/test-dispatch-executor-thread.sh — executor threads task -> run_one -> worker
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-executor-thread-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-executor-thread"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

CWD="$WORK/repo"; mkdir -p "$CWD"; (cd "$CWD" && git init -q)

# Mock worker: record the 6th arg (executor) and satisfy the AC below.
_ccs_dispatch_run_worker() {
  local run_dir="$3" attempt="$4" executor="${6:-claude}"
  echo "$executor" >> "$WORK/seen-executor.log"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"
  : > "$CWD/done.txt"
  return 0
}

mk() {  # mk <file> <executor-line-or-empty>
  local f="$WORK/$1" ex="$2"
  { echo "id: t"; echo "goal: g";
    [ -n "$ex" ] && echo "$ex";
    echo "scope: {cwd: \"$CWD\"}";
    echo "acceptance_criteria:";
    echo "  - id: AC1";
    echo "    text: t";
    echo "    verify: {cmd: \"test -f $CWD/done.txt\"}"; } > "$f"
  echo "$f"
}

echo "=== gemini task threads gemini to worker ==="
: > "$WORK/seen-executor.log"; rm -f "$CWD/done.txt"
d="$(_ccs_dispatch_run "$(mk g.yaml 'executor: gemini')")"
assert_contains "worker saw gemini" "$(cat "$WORK/seen-executor.log")" "gemini"
assert_eq "gate verdict written" "PASS" \
  "$(jq -r '.verdict' "$d"/hop-*/attempt-01/gate/verdict.json)"

echo "=== omitted executor threads claude to worker ==="
: > "$WORK/seen-executor.log"; rm -f "$CWD/done.txt"
_ccs_dispatch_run "$(mk n.yaml '')" >/dev/null
assert_eq "worker saw claude" "claude" "$(head -1 "$WORK/seen-executor.log")"
