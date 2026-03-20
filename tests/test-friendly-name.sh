#!/usr/bin/env bash
# tests/test-friendly-name.sh — verify _ccs_friendly_project_name output
set -euo pipefail
cd "$(dirname "$0")/.."
source ccs-core.sh

pass=0 fail=0

assert_eq() {
  local input="$1" expected="$2"
  local actual
  actual=$(_ccs_friendly_project_name "$input")
  if [ "$actual" = "$expected" ]; then
    printf '  PASS: %s → %s\n' "$input" "$actual"
    pass=$((pass + 1))
  else
    printf '  FAIL: %s → got "%s", expected "%s"\n' "$input" "$actual" "$expected"
    fail=$((fail + 1))
  fi
}

echo "=== _ccs_friendly_project_name tests ==="

# Home
assert_eq "-pool2-chenhsun" "~(home)"

# Normal projects
assert_eq "-pool2-chenhsun-tools-ccs-dashboard" "ccs-dashboard"
assert_eq "-pool2-chenhsun-works-git-specman" "specman"

# Worktree: --worktrees-
assert_eq "-pool2-chenhsun-MD330-sdk-x3--worktrees-streaming-stm-wtv5" "sdk_x3/streaming-stm-wtv5"

# Worktree: --claude-worktrees-
assert_eq "-pool2-chenhsun-works-git-specman--claude-worktrees-md330-doc-scaffold" "specman/md330-doc-scaffold"
assert_eq "-pool2-chenhsun-RK3576-tig4--claude-worktrees-specman-analysis" "tig4/specman-analysis"
assert_eq "-pool2-chenhsun-works-git-ai-agents--claude-worktrees-feat-gitman-skills-refactor" "ai_agents/feat-gitman-skills-refactor"

# Worktree: --dev-worktree-
assert_eq "-pool2-chenhsun-works-git-specman--dev-worktree-quick-river" "specman/quick-river"

# Triple dash (NOT a worktree)
assert_eq "-pool2-chenhsun---works-git-specman" "specman"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
