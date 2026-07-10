#!/usr/bin/env bash
# tests/test-gate-chain-cli.sh — CLI output for single vs multi hop
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-chain-cli-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-chain-cli"; rm -rf "$WORK"
mkdir -p "$WORK/repo"; _TEST_DIRS+=("$WORK")
_ccs_dispatch_run_worker() {
  local run_dir="$3" attempt="$4"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"; return 0
}
mk() {
  { printf 'id: %s\ngoal: g\nscope: { cwd: "%s" }\n' "$2" "$WORK/repo"
    [ -n "${3:-}" ] && printf 'next: %s\n' "$3"
    printf 'acceptance_criteria:\n  - id: AC1\n    text: t\n    verify: { cmd: "true" }\n'
  } > "$1"
}

echo "=== single hop -> outcome: line ==="
mk "$WORK/s1.yaml" s1
out="$(ccs-dispatch-run "$WORK/s1.yaml")"; rc=$?
assert_eq "exit 0" "0" "$rc"
assert_contains "prints run:" "$out" "run:"
assert_contains "single-hop outcome line" "$out" "outcome: accepted"

echo "=== two hops -> chain: line ==="
mk "$WORK/m1.yaml" m1 m2.yaml
mk "$WORK/m2.yaml" m2
out2="$(ccs-dispatch-run "$WORK/m1.yaml")"
assert_contains "chain summary line" "$out2" "chain: 2 hops"
assert_contains "chain outcome accepted" "$out2" "outcome=accepted"

echo "=== chain.json shape ==="
cd_dir="$(_ccs_dispatch_run "$WORK/m1.yaml")"
assert_eq "chain_id present" "yes" \
  "$([ -n "$(jq -r '.chain_id' "$cd_dir/chain.json")" ] && echo yes)"
assert_eq "two hop records" "2" "$(jq -r '.hops|length' "$cd_dir/chain.json")"
assert_eq "stop_reason empty-next" "empty-next" \
  "$(jq -r '.stop_reason' "$cd_dir/chain.json")"

test_summary
