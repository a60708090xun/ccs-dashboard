#!/usr/bin/env bash
# tests/test-gate-chain-loop.sh — multi-hop PASS-continue / non-PASS-stop
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-chain-loop-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-chain-loop"; rm -rf "$WORK"
mkdir -p "$WORK/repo"; _TEST_DIRS+=("$WORK")

# Two-hop chain: t1 creates a.txt, t2 creates b.txt. Both cmd-ACs check the
# file exists in the shared repo cwd.
cat > "$WORK/t1.yaml" <<YAML
id: t1
goal: "make a"
scope: { cwd: "$WORK/repo" }
next: t2.yaml
acceptance_criteria:
  - id: AC1
    text: "a exists"
    verify: { cmd: "test -f a.txt" }
YAML
cat > "$WORK/t2.yaml" <<YAML
id: t2
goal: "make b"
scope: { cwd: "$WORK/repo" }
acceptance_criteria:
  - id: AC1
    text: "b exists"
    verify: { cmd: "test -f b.txt" }
YAML

# Mock worker: create the file named after the hop's goal.
_ccs_dispatch_run_worker() {
  local cwd="$1" prompt="$2" run_dir="$3" attempt="$4"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"
  case "$prompt" in
    *"make a"*) : > "$cwd/a.txt" ;;
    *"make b"*) : > "$cwd/b.txt" ;;
  esac
  return 0
}

echo "=== 2-hop all PASS -> both hops run, exit 0 ==="
cd "$WORK/repo"; rm -f a.txt b.txt
chain_dir="$(_ccs_dispatch_run "$WORK/t1.yaml")"; rc=$?
assert_eq "exit 0" "0" "$rc"
assert_eq "hop1 accepted" "accepted" \
  "$(jq -r '.outcome' "$chain_dir/hop-01-t1/final.json")"
assert_eq "hop2 accepted" "accepted" \
  "$(jq -r '.outcome' "$chain_dir/hop-02-t2/final.json")"

echo "=== hop1 ESCALATE -> stop, hop2 never runs, exit 10 ==="
# Worker that never makes a.txt -> AC1 FAIL -> (budget 1) ESCALATE.
_ccs_dispatch_run_worker() {
  local run_dir="$3" attempt="$4"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"; return 0
}
cd "$WORK/repo"; rm -f a.txt b.txt
chain_dir2="$(_ccs_dispatch_run "$WORK/t1.yaml")"; rc2=$?
assert_eq "exit 10" "10" "$rc2"
assert_eq "hop1 escalated" "escalated" \
  "$(jq -r '.outcome' "$chain_dir2/hop-01-t1/final.json")"
assert_eq "hop2 dir absent" "no" \
  "$([ -d "$chain_dir2/hop-02-t2" ] && echo yes || echo no)"

test_summary
