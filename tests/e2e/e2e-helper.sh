#!/usr/bin/env bash
# tests/e2e/e2e-helper.sh — E2E test helper
# Provides mock directory scaffolding for
# scenario-based E2E tests.
#
# Requires: fixture-helper.sh sourced first
# Usage:
#   source tests/fixture-helper.sh
#   source tests/e2e/e2e-helper.sh
#   source ccs-dashboard.sh

# ── Mock Directory Structure ──

# setup_e2e_dir NAME
#   Creates test dir, mock projects dir,
#   and exports CCS_PROJECTS_DIR.
setup_e2e_dir() {
  local name="${1:?missing e2e test name}"
  setup_test_dir "$name"
  mkdir -p "$TEST_DIR/projects"
  export CCS_PROJECTS_DIR="$TEST_DIR/projects"
}

# create_mock_session SLUG SID
#   Creates $CCS_PROJECTS_DIR/$SLUG/$SID.jsonl
#   Exports SESSION_FILE. Echoes path.
create_mock_session() {
  local slug="${1:?missing project slug}"
  local sid="${2:?missing session id}"
  local pdir="$CCS_PROJECTS_DIR/$slug"
  mkdir -p "$pdir"
  SESSION_FILE="$pdir/${sid}.jsonl"
  touch "$SESSION_FILE"
  export SESSION_FILE
  echo "$SESSION_FILE"
}

# write_prompts FILE COUNT
#   Appends COUNT user+assistant exchanges
#   to FILE, with sequential timestamps.
write_prompts() {
  local file="$1" count="$2"
  local i
  for (( i = 1; i <= count; i++ )); do
    local ts
    ts=$(printf '2026-03-27T09:%02d:00Z' "$i")
    local ts2
    ts2=$(printf '2026-03-27T09:%02d:30Z' "$i")
    echo "{\"type\":\"user\",\"message\":{\"content\":\"prompt $i\"},\"timestamp\":\"$ts\"}" >> "$file"
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply $i\"}]},\"timestamp\":\"$ts2\"}" >> "$file"
  done
}

# ── External Dependency Mocks ──

# mock_no_active_process
#   Override fuser so no session looks active.
mock_no_active_process() {
  fuser() { return 1; }
  export -f fuser
}
