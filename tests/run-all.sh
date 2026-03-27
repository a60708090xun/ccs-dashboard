#!/usr/bin/env bash
# tests/run-all.sh — run all test files
# Run: bash tests/run-all.sh
set -euo pipefail
cd "$(dirname "$0")"

total=0 passed=0 failed=0 skipped=0
failed_tests=()

# Tests requiring live session data
SKIP_LIVE=(
  "test-crash-detect.sh"
)

# Registered test files (auto-discovered by glob test-*.sh):
#   test-checkpoint-improvements.sh
#   test-core.sh
#   test-crash-clean-by-id.sh
#   test-dispatch.sh
#   test-friendly-name.sh
#   test-handoff.sh
#   test-health.sh
#   test-ops.sh
#   test-status.sh

for t in test-*.sh; do
  # Check skip list
  skip=false
  for s in "${SKIP_LIVE[@]}"; do
    [ "$t" = "$s" ] && skip=true
  done
  if $skip; then
    echo ""
    echo "══ $t (SKIP: live data) ══"
    skipped=$((skipped + 1))
    continue
  fi

  echo ""
  echo "══ $t ══"
  total=$((total + 1))
  if bash "$t"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failed_tests+=("$t")
  fi
done

echo ""
echo "════════════════════════"
echo "Total: $total  Passed: $passed  Failed: $failed  Skipped: $skipped"
if [ "$failed" -gt 0 ]; then
  echo "Failed:"
  for f in "${failed_tests[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
