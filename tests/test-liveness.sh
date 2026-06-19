#!/usr/bin/env bash
# tests/test-liveness.sh — _ccs_liveness_classify (pure allocation) tests
# Run: bash tests/test-liveness.sh
#
# _ccs_liveness_classify is the PURE core of process-liveness detection: given
# session records + per-group live entry-process counts, it decides which
# sessions are backed by a live process (alive) and which are orphaned (dead).
# It does NOT query processes, so it is fully unit-testable with fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh

setup_test_dir "liveness"

# Run classifier: $1 = countfile contents, stdin = records.
# Echoes verdict lines "sid<TAB>alive|dead".
_run() { # $1 countfile-contents ; stdin = records
  local cf="$TEST_DIR/count.tsv"
  printf '%b' "$1" > "$cf"
  _ccs_liveness_classify "$cf"
}

echo "=== _ccs_liveness_classify ==="

# T1: single session, one process -> alive
out=$(printf 's1\tC:cwd1\t1000\t0\n' | _run 'C:cwd1\t1\n')
assert_contains "T1: lone session with a process is alive" "$out" "s1	alive"

# T2: two sessions, one process -> newest alive, oldest dead
out=$(printf 's_old\tC:cwd1\t1000\t0\ns_new\tC:cwd1\t2000\t0\n' | _run 'C:cwd1\t1\n')
assert_contains "T2: newest of two keeps the slot" "$out" "s_new	alive"
assert_contains "T2: oldest of two is orphaned" "$out" "s_old	dead"

# T3: two sessions, zero processes -> both dead (group absent from countfile)
out=$(printf 's1\tC:cwd1\t1000\t0\ns2\tC:cwd1\t2000\t0\n' | _run '')
assert_contains "T3a: no process -> first dead" "$out" "s1	dead"
assert_contains "T3b: no process -> second dead" "$out" "s2	dead"

# T4: exact-sid session is always alive and consumes the slot, even if older
out=$(printf 's_exact\tC:cwd1\t1000\t1\ns_new\tC:cwd1\t2000\t0\n' | _run 'C:cwd1\t1\n')
assert_contains "T4a: exact-sid pinned alive despite older mtime" "$out" "s_exact	alive"
assert_contains "T4b: newer non-exact loses to consumed slot" "$out" "s_new	dead"

# T5: exact + spare slot -> exact alive AND newest non-exact alive
out=$(printf 's_exact\tC:cwd1\t1000\t1\ns_new\tC:cwd1\t3000\t0\ns_mid\tC:cwd1\t2000\t0\n' | _run 'C:cwd1\t2\n')
assert_contains "T5a: exact alive" "$out" "s_exact	alive"
assert_contains "T5b: newest non-exact takes spare slot" "$out" "s_new	alive"
assert_contains "T5c: older non-exact orphaned" "$out" "s_mid	dead"

# T6: provider/group isolation — same cwd, different provider
out=$(printf 'c1\tC:cwd1\t1000\t0\ng1\tG:cwd1\t1000\t0\n' | _run 'C:cwd1\t1\n')
assert_contains "T6a: claude session alive (C has a process)" "$out" "c1	alive"
assert_contains "T6b: gemini session dead (G has no process)" "$out" "g1	dead"

# T7: more processes than sessions -> all alive (never over-kill)
out=$(printf 's1\tC:cwd1\t1000\t0\ns2\tC:cwd1\t2000\t0\n' | _run 'C:cwd1\t5\n')
assert_contains "T7a: surplus slots keep s1 alive" "$out" "s1	alive"
assert_contains "T7b: surplus slots keep s2 alive" "$out" "s2	alive"

# T8: exact_count exceeds proc_count -> exacts still alive, remainder floored at 0
out=$(printf 'e1\tC:cwd1\t1000\t1\ne2\tC:cwd1\t2000\t1\nn1\tC:cwd1\t3000\t0\n' | _run 'C:cwd1\t1\n')
assert_contains "T8a: first exact alive" "$out" "e1	alive"
assert_contains "T8b: second exact alive (exact never killed)" "$out" "e2	alive"
assert_contains "T8c: non-exact dead (no slots left)" "$out" "n1	dead"

test_summary
