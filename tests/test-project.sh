#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/fixture-helper.sh
source ccs-core.sh
source ccs-feature.sh
source ccs-review.sh
source ccs-project.sh

setup_test_dir "project"

echo "=== _ccs_project_collect: basic session collection ==="

# Setup: fake projects dir with two projects
export CCS_PROJECTS_DIR="$TEST_DIR/projects"
PROJ_A="$TEST_DIR/projects/-pool2-user-repo-alpha"
PROJ_B="$TEST_DIR/projects/-pool2-user-repo-beta"
mkdir -p "$PROJ_A" "$PROJ_B"

# Create JSONL files for project A (3 sessions)
for i in 1 2 3; do
  cat > "$PROJ_A/session-${i}.jsonl" <<JSONL
{"type":"user","message":{"content":"task $i"},"timestamp":"2026-03-0${i}T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"done $i"}]},"timestamp":"2026-03-0${i}T10:30:00Z"}
JSONL
  touch_minutes_ago "$PROJ_A/session-${i}.jsonl" $((i * 1440))
done

# Create JSONL for project B (should not appear)
cat > "$PROJ_B/session-b1.jsonl" <<'JSONL'
{"type":"user","message":{"content":"other project"},"timestamp":"2026-03-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-03-01T10:30:00Z"}
JSONL

# Test: collect for project A by encoded dir name
result=$(_ccs_project_collect "-pool2-user-repo-alpha")
count=$(echo "$result" | grep -c '.jsonl' || true)
assert_eq "collect: 3 sessions for alpha" "3" "$count"

# Test: no beta sessions mixed in
beta_count=$(echo "$result" | grep -c 'beta' || true)
assert_eq "collect: no beta sessions" "0" "$beta_count"

echo "=== _ccs_project_collect: sorted by mtime descending ==="

# Most recent file (1 day ago) should be first
first_file=$(echo "$result" | head -1)
assert_contains "collect: newest first" "$first_file" "session-1.jsonl"

echo "=== _ccs_project_collect: auto-truncation by count ==="

# Create 55 sessions to test 50-cap
for i in $(seq 4 55); do
  cat > "$PROJ_A/session-many-${i}.jsonl" <<JSONL
{"type":"user","message":{"content":"task $i"},"timestamp":"2026-03-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"timestamp":"2026-03-01T10:30:00Z"}
JSONL
  touch_minutes_ago "$PROJ_A/session-many-${i}.jsonl" $((i * 10))
done

result=$(_ccs_project_collect "-pool2-user-repo-alpha")
count=$(echo "$result" | grep -c '.jsonl' || true)
assert_eq "collect: capped at 50" "50" "$count"

echo "=== _ccs_project_cost: cost aggregation ==="

COST_DIR="$TEST_DIR/projects/-pool2-user-repo-cost"
mkdir -p "$COST_DIR"

cat > "$COST_DIR/sess-cost-1.jsonl" <<'JSONL'
{"type":"user","message":{"content":"task one"},"timestamp":"2026-04-01T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it."}]},"timestamp":"2026-04-01T10:15:00Z"}
{"type":"user","message":{"content":"continue"},"timestamp":"2026-04-01T10:16:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]},"timestamp":"2026-04-01T10:30:00Z"}
JSONL

cat > "$COST_DIR/sess-cost-2.jsonl" <<'JSONL'
{"type":"user","message":{"content":"task two"},"timestamp":"2026-04-02T14:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"OK."}]},"timestamp":"2026-04-02T14:20:00Z"}
JSONL

touch_minutes_ago "$COST_DIR/sess-cost-1.jsonl" 1440
touch_minutes_ago "$COST_DIR/sess-cost-2.jsonl" 60

cost_json=$(_ccs_project_cost "-pool2-user-repo-cost")
assert_eq "cost: session_count" "2" "$(echo "$cost_json" | jq '.session_count')"
assert_eq "cost: total_rounds" "3" "$(echo "$cost_json" | jq '.total_rounds')"
assert_eq "cost: total_duration" "50" "$(echo "$cost_json" | jq '.total_duration_min')"
assert_eq "cost: has estimated_hours" "true" "$(echo "$cost_json" | jq 'has("estimated_hours")')"

echo "=== _ccs_project_features: filter features by project ==="

export CCS_DATA_DIR="$TEST_DIR/data"
mkdir -p "$CCS_DATA_DIR"
cat > "$CCS_DATA_DIR/features.jsonl" <<'JSONL'
{"id":"alpha/gh1","label":"Add login","project":"/pool2/user/repo-alpha","sessions":["sess1","sess2"],"branch":"feat/login","status":"completed","todos_done":5,"todos_total":5,"last_active_min":1440,"last_exchange":"Done","git_dirty":0,"updated":"2026-04-01T10:00:00"}
{"id":"alpha/gh2","label":"Fix bug","project":"/pool2/user/repo-alpha","sessions":["sess3"],"branch":"fix/crash","status":"in_progress","todos_done":2,"todos_total":4,"last_active_min":30,"last_exchange":"Working","git_dirty":3,"updated":"2026-04-07T10:00:00"}
{"id":"beta/gh5","label":"Other project","project":"/pool2/user/repo-beta","sessions":["sess9"],"branch":"feat/x","status":"idle","todos_done":0,"todos_total":1,"last_active_min":9999,"last_exchange":"","git_dirty":0,"updated":"2026-03-01T10:00:00"}
{"id":"_ungrouped","sessions":["sess99"]}
JSONL

features_json=$(_ccs_project_features "/pool2/user/repo-alpha")
feat_count=$(echo "$features_json" | jq 'length')
assert_eq "features: 2 for alpha" "2" "$feat_count"

statuses=$(echo "$features_json" | jq -r '.[].status' | sort | tr '\n' ',')
assert_contains "features: has completed" "$statuses" "completed"
assert_contains "features: has in_progress" "$statuses" "in_progress"

echo "=== _ccs_project_rhythm: rhythm analysis ==="

RHYTHM_DIR="$TEST_DIR/projects/-pool2-user-repo-rhythm"
mkdir -p "$RHYTHM_DIR"

# Days: Apr 1, 2, 3 (streak=3), gap, Apr 6, 7 (streak=2)
# Gap = 2 days (Apr 4, 5)
for day in 01 02 03 06 07; do
  cat > "$RHYTHM_DIR/sess-d${day}.jsonl" <<JSONL
{"type":"user","message":{"content":"work on day $day"},"timestamp":"2026-04-${day}T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"timestamp":"2026-04-${day}T10:30:00Z"}
JSONL
done
# Two sessions on Apr 1
cat > "$RHYTHM_DIR/sess-d01b.jsonl" <<'JSONL'
{"type":"user","message":{"content":"second session"},"timestamp":"2026-04-01T14:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-04-01T14:20:00Z"}
JSONL

# Set mtimes within 90-day window
touch_minutes_ago "$RHYTHM_DIR/sess-d01.jsonl" $((7 * 1440))
touch_minutes_ago "$RHYTHM_DIR/sess-d01b.jsonl" $((7 * 1440 - 240))
touch_minutes_ago "$RHYTHM_DIR/sess-d02.jsonl" $((6 * 1440))
touch_minutes_ago "$RHYTHM_DIR/sess-d03.jsonl" $((5 * 1440))
touch_minutes_ago "$RHYTHM_DIR/sess-d06.jsonl" $((2 * 1440))
touch_minutes_ago "$RHYTHM_DIR/sess-d07.jsonl" $((1 * 1440))

rhythm_json=$(_ccs_project_rhythm "-pool2-user-repo-rhythm")
assert_eq "rhythm: longest_streak" "3" "$(echo "$rhythm_json" | jq '.longest_streak')"
assert_eq "rhythm: longest_gap" "2" "$(echo "$rhythm_json" | jq '.longest_gap')"
assert_eq "rhythm: active_days" "5" "$(echo "$rhythm_json" | jq '.heatmap | length')"

apr1_count=$(echo "$rhythm_json" | jq '.heatmap[] | select(.date == "2026-04-01") | .sessions')
assert_eq "rhythm: apr1 has 2 sessions" "2" "$apr1_count"

echo "=== _ccs_project_code_changes: git analysis ==="

CODE_REPO="$TEST_DIR/repo-code"
mkdir -p "$CODE_REPO"
git -C "$CODE_REPO" init --quiet
git -C "$CODE_REPO" symbolic-ref HEAD refs/heads/master
git -C "$CODE_REPO" config user.email "test@test.com"
git -C "$CODE_REPO" config user.name "Test"

# Initial commit
echo "line1" > "$CODE_REPO/main.sh"
git -C "$CODE_REPO" add main.sh
git -C "$CODE_REPO" commit -m "init" --quiet

# Feature branch with commits
git -C "$CODE_REPO" checkout -b feat/login --quiet
echo "line2" >> "$CODE_REPO/main.sh"
echo "new file" > "$CODE_REPO/auth.sh"
git -C "$CODE_REPO" add -A
git -C "$CODE_REPO" commit -m "feat: add auth" --quiet
echo "line3" >> "$CODE_REPO/main.sh"
git -C "$CODE_REPO" add -A
git -C "$CODE_REPO" commit -m "feat: extend auth" --quiet

# Back to master with another commit
git -C "$CODE_REPO" checkout master --quiet
echo "fix" >> "$CODE_REPO/main.sh"
git -C "$CODE_REPO" add -A
git -C "$CODE_REPO" commit -m "fix: typo" --quiet

changes_json=$(_ccs_project_code_changes "$CODE_REPO" "90")
assert_eq "code: has by_branch" "true" "$(echo "$changes_json" | jq 'has("by_branch")')"
assert_eq "code: has top_files" "true" "$(echo "$changes_json" | jq 'has("top_files")')"
assert_eq "code: has lines_added" "true" "$(echo "$changes_json" | jq 'has("lines_added")')"

branch_count=$(echo "$changes_json" | jq '.by_branch | length')
assert_eq "code: 2 branches" "2" "$branch_count"

echo "=== _ccs_project_json: full JSON assembly ==="

# Reuse COST_DIR from earlier test (has 2 sessions)
# Create a git repo at a mock "resolved" path
PROJ_REPO="$TEST_DIR/pool2/user/repo-cost"
mkdir -p "$PROJ_REPO"
git -C "$PROJ_REPO" init --quiet
git -C "$PROJ_REPO" symbolic-ref HEAD refs/heads/master
git -C "$PROJ_REPO" config user.email "test@test.com"
git -C "$PROJ_REPO" config user.name "Test"
echo "init" > "$PROJ_REPO/main.sh"
git -C "$PROJ_REPO" add main.sh
git -C "$PROJ_REPO" commit -m "init" --quiet

# Mock _ccs_resolve_project_path for this test
_ccs_resolve_project_path() {
  echo "$PROJ_REPO"
}

project_json=$(_ccs_project_json "-pool2-user-repo-cost")
assert_eq "json: has project" "true" "$(echo "$project_json" | jq 'has("project")')"
assert_eq "json: has period" "true" "$(echo "$project_json" | jq 'has("period")')"
assert_eq "json: has cost" "true" "$(echo "$project_json" | jq 'has("cost")')"
assert_eq "json: has features" "true" "$(echo "$project_json" | jq 'has("features")')"
assert_eq "json: has rhythm" "true" "$(echo "$project_json" | jq 'has("rhythm")')"
assert_eq "json: has code_changes" "true" "$(echo "$project_json" | jq 'has("code_changes")')"
assert_eq "json: has sessions" "true" "$(echo "$project_json" | jq 'has("sessions")')"
assert_eq "json: session_count matches" "2" "$(echo "$project_json" | jq '.period.session_count')"
assert_eq "json: insights null" "null" "$(echo "$project_json" | jq '.insights')"

test_summary
