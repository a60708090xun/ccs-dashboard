#!/usr/bin/env bash
# tests/fixture-helper.sh — shared test utilities
# Requires GNU coreutils (touch -d)
# Usage: source fixture-helper.sh

PASS=0 FAIL=0

_TEST_DIRS=()

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n' "$label"
    printf '    expected: %s\n' "$expected"
    printf '    actual:   %s\n' "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s (not found: "%s")\n' \
      "$label" "$needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    printf '  FAIL: %s (found: "%s")\n' \
      "$label" "$needle"
    FAIL=$((FAIL + 1))
  else
    printf '  PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  fi
}

setup_test_dir() {
  local name="${1:?missing test name}"
  TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." \
    && pwd)/tmp/test-${name}"
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"
  _TEST_DIRS+=("$TEST_DIR")
  trap '_cleanup_test_dirs' EXIT
}

_cleanup_test_dirs() {
  for _d in "${_TEST_DIRS[@]}"; do
    rm -rf "$_d"
  done
}

touch_minutes_ago() {
  local file="$1" minutes="$2"
  touch -d "${minutes} minutes ago" "$file"
}

strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

test_summary() {
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] || exit 1
}
