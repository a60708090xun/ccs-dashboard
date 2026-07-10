#!/usr/bin/env bash
# tests/test-gate-chain-guards.sh — cycle / depth / missing-next guards
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-chain-guards-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-chain-guards"; rm -rf "$WORK"
mkdir -p "$WORK/repo"; _TEST_DIRS+=("$WORK")

# Always-PASS worker (cmd AC is `true`).
_ccs_dispatch_run_worker() {
  local run_dir="$3" attempt="$4"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"; return 0
}
mk() {  # mk <file> <id> [next]
  { printf 'id: %s\ngoal: g\nscope: { cwd: "%s" }\n' "$2" "$WORK/repo"
    [ -n "${3:-}" ] && printf 'next: %s\n' "$3"
    printf 'acceptance_criteria:\n  - id: AC1\n    text: t\n    verify: { cmd: "true" }\n'
  } > "$1"
}

echo "=== cycle: t1->t2->t1 stops with reason cycle ==="
mk "$WORK/c1.yaml" c1 c2.yaml
mk "$WORK/c2.yaml" c2 c1.yaml
cd "$WORK/repo"
cd_dir="$(_ccs_dispatch_run "$WORK/c1.yaml")"
assert_eq "stop_reason cycle" "cycle" "$(jq -r '.stop_reason' "$cd_dir/chain.json")"

echo "=== missing next file stops with reason failed ==="
mk "$WORK/m1.yaml" m1 nope.yaml
md_dir="$(_ccs_dispatch_run "$WORK/m1.yaml")"
assert_eq "stop_reason failed" "failed" "$(jq -r '.stop_reason' "$md_dir/chain.json")"

echo "=== depth cap stops with reason depth ==="
# Build a linear chain longer than the cap; each links to the next.
export CCS_DISPATCH_CHAIN_MAX_DEPTH=2
mk "$WORK/d1.yaml" d1 d2.yaml
mk "$WORK/d2.yaml" d2 d3.yaml
mk "$WORK/d3.yaml" d3 d4.yaml
mk "$WORK/d4.yaml" d4          # would be hop 4; cap stops earlier
dd_dir="$(_ccs_dispatch_run "$WORK/d1.yaml")"
assert_eq "stop_reason depth" "depth" "$(jq -r '.stop_reason' "$dd_dir/chain.json")"
assert_eq "ran depth+1 hops" "3" "$(jq -r '.hops|length' "$dd_dir/chain.json")"
unset CCS_DISPATCH_CHAIN_MAX_DEPTH

test_summary
