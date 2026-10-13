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
cd_dir="$(_ccs_dispatch_run "$WORK/c1.yaml")"; crc=$?
assert_eq "stop_reason cycle" "cycle" "$(jq -r '.stop_reason' "$cd_dir/chain.json")"
# The hop c2 declared never ran, so the chain must not end accepted (#125).
assert_eq "cycle -> outcome escalated" "escalated" "$(jq -r '.outcome' "$cd_dir/chain.json")"
assert_eq "cycle -> rc 10" "10" "$crc"
assert_contains "cycle stop_detail names the path" \
  "$(jq -r '.stop_detail' "$cd_dir/chain.json")" "c1.yaml"

echo "=== missing next file stops with reason failed ==="
mk "$WORK/m1.yaml" m1 nope.yaml
md_dir="$(_ccs_dispatch_run "$WORK/m1.yaml")"; mrc=$?
assert_eq "stop_reason failed" "failed" "$(jq -r '.stop_reason' "$md_dir/chain.json")"
assert_eq "missing next -> outcome escalated" "escalated" "$(jq -r '.outcome' "$md_dir/chain.json")"
assert_eq "missing next -> rc 10" "10" "$mrc"
assert_contains "missing next stop_detail is the loader message" \
  "$(jq -r '.stop_detail' "$md_dir/chain.json")" "task file not found"

echo "=== invalid next file (removed executor) stops escalated with loader message ==="
mk "$WORK/w1.yaml" w1 w2.yaml
mk "$WORK/w2.yaml" w2
printf 'executor: wingman\n' >> "$WORK/w2.yaml"
wd_dir="$(_ccs_dispatch_run "$WORK/w1.yaml")"; wrc=$?
assert_eq "invalid next -> stop_reason failed" "failed" "$(jq -r '.stop_reason' "$wd_dir/chain.json")"
assert_eq "invalid next -> outcome escalated" "escalated" "$(jq -r '.outcome' "$wd_dir/chain.json")"
assert_eq "invalid next -> rc 10" "10" "$wrc"
assert_contains "invalid next stop_detail is the loader message" \
  "$(jq -r '.stop_detail' "$wd_dir/chain.json")" "use executor: opencode"
assert_eq "invalid next -> stopped at hop 1" "1" "$(jq -r '.stopped_at_hop' "$wd_dir/chain.json")"
# I4: the chain-level escalation must not rewrite the hop's own gate verdict.
assert_eq "invalid next -> hop 1 keeps its gate verdict" "accepted" \
  "$(jq -r '.hops[0].outcome' "$wd_dir/chain.json")"
assert_eq "invalid next -> no stderr file left" "absent" \
  "$([ ! -e "$wd_dir/next-load.stderr" ] && echo absent || echo present)"

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
# depth is a deliberate cap and stays accepted / 0 (#125 scope).
dd_dir="$(_ccs_dispatch_run "$WORK/d1.yaml")"; drc=$?
assert_eq "depth -> outcome accepted" "accepted" "$(jq -r '.outcome' "$dd_dir/chain.json")"
assert_eq "depth -> rc 0" "0" "$drc"
assert_eq "depth -> stop_detail null" "null" "$(jq -r '.stop_detail' "$dd_dir/chain.json")"
assert_eq "successful loads leave no stderr file" "absent" \
  "$([ ! -e "$dd_dir/next-load.stderr" ] && echo absent || echo present)"
unset CCS_DISPATCH_CHAIN_MAX_DEPTH

test_summary
