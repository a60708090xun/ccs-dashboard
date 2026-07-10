#!/usr/bin/env bash
# tests/test-gate-chain-helpers.sh — path + chain-dir helpers
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-chain-helpers-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-chain-helpers"; rm -rf "$WORK"
mkdir -p "$WORK/a/b"; _TEST_DIRS+=("$WORK")

echo "=== resolve_next relative to cur's dir ==="
assert_eq "relative sibling" "$WORK/a/t2.yaml" \
  "$(_ccs_dispatch_resolve_next "$WORK/a/t1.yaml" "t2.yaml")"
assert_eq "relative with .." "$WORK/t3.yaml" \
  "$(_ccs_dispatch_resolve_next "$WORK/a/t1.yaml" "../t3.yaml")"
assert_eq "absolute passthrough" "/etc/x.yaml" \
  "$(_ccs_dispatch_resolve_next "$WORK/a/t1.yaml" "/etc/x.yaml")"

echo "=== abspath normalizes ==="
assert_eq "normalizes .." "$WORK/t3.yaml" \
  "$(_ccs_dispatch_abspath "$WORK/a/../t3.yaml")"

echo "=== chain_alloc_dir claims fresh dirs ==="
d1="$(_ccs_dispatch_chain_alloc_dir myid)"
d2="$(_ccs_dispatch_chain_alloc_dir myid)"
assert_eq "first is -chain-01" "myid-chain-01" "$(basename "$d1")"
assert_eq "second is -chain-02" "myid-chain-02" "$(basename "$d2")"
assert_eq "d1 exists" "yes" "$([ -d "$d1" ] && echo yes)"

test_summary
