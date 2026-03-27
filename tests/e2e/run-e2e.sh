#!/usr/bin/env bash
# tests/e2e/run-e2e.sh — run all E2E tests
set -euo pipefail
cd "$(dirname "$0")"

total=0 passed=0 failed=0 skipped=0
failed_tests=()

SKIP=(
  # Add tests to skip here
)

for t in test-*-e2e.sh; do
  skip=false
  for s in "${SKIP[@]+"${SKIP[@]}"}"; do
    [ "$t" = "$s" ] && skip=true
  done
  if $skip; then
    echo ""
    echo "══ $t (SKIP) ══"
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
echo "E2E: $total  Passed: $passed  Failed: $failed  Skipped: $skipped"
if [ "$failed" -gt 0 ]; then
  echo "Failed:"
  for f in "${failed_tests[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
