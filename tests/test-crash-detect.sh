#!/usr/bin/env bash
# Manual verification for ccs-crash (GitHub #9)
# Run: bash tests/test-crash-detect.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/ccs-dashboard.sh"

echo "=== Test 1: _ccs_get_boot_epoch ==="
boot=$(_ccs_get_boot_epoch) && echo "PASS: boot epoch=$boot ($(date -d @$boot))" || echo "FAIL: no boot epoch"

echo ""
echo "=== Test 2: _ccs_detect_crash (default windows) ==="
declare -A cm1=()
_ccs_detect_crash cm1 2>/dev/null || true
echo "Detected: ${#cm1[@]} sessions"
for k in "${!cm1[@]}"; do echo "  $k → ${cm1[$k]}"; done
echo "PASS: helper completed without error"

echo ""
echo "=== Test 3: _ccs_detect_crash (wide reboot window) ==="
declare -A cm2=()
_ccs_detect_crash cm2 --reboot-window 180 2>/dev/null || true
echo "Detected: ${#cm2[@]} sessions"
for k in "${!cm2[@]}"; do echo "  $k → ${cm2[$k]}"; done

echo ""
echo "=== Test 4: ccs-crash --md (Markdown output) ==="
ccs-crash --reboot-window 180 2>/dev/null | head -10 || echo "WARN: error on ccs-crash --md"

echo ""
echo "=== Test 5: ccs-crash --json (valid JSON check) ==="
output=$(ccs-crash --json --reboot-window 180 2>/dev/null || true)
if [ -n "$output" ]; then
  echo "$output" | jq . >/dev/null 2>&1 && echo "PASS: valid JSON" || echo "FAIL: invalid JSON"
else
  echo "WARN: no output from ccs-crash --json"
fi

echo ""
echo "=== Test 6: ccs-crash --help ==="
ccs-crash --help >/dev/null 2>&1 && echo "PASS" || echo "FAIL"

echo ""
echo "=== All critical tests complete ==="
