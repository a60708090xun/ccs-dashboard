#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/ccs-dashboard.sh"

echo "=== Test 1: _ccs_dispatch_job_id ==="
id=$(_ccs_dispatch_job_id)
echo "Generated: $id"
if [[ "$id" =~ ^d-[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$ ]]; then
  echo "PASS: format OK"
else
  echo "FAIL: bad format"
  exit 1
fi

id2=$(_ccs_dispatch_job_id)
if [ "$id" != "$id2" ]; then
  echo "PASS: unique"
else
  echo "FAIL: duplicate"
  exit 1
fi

echo ""
echo "=== Test 2: JSONL append + latest ==="
id=$(_ccs_dispatch_job_id)
_ccs_dispatch_jsonl_append \
  "{\"job_id\":\"$id\",\"status\":\"running\"}"
_ccs_dispatch_jsonl_append \
  "{\"job_id\":\"$id\",\"status\":\"completed\"}"
latest=$(_ccs_dispatch_jsonl_latest "$id")
status=$(echo "$latest" | jq -r '.status')
if [ "$status" = "completed" ]; then
  echo "PASS: latest-wins"
else
  echo "FAIL: got $status"
  exit 1
fi

echo ""
echo "=== Test 3: E2E dry-run (sync) ==="
mock_dir="$SCRIPT_DIR/tmp/ccs-test-bin"
test_proj="$SCRIPT_DIR/tmp/ccs-test-proj"
mkdir -p "$mock_dir" "$test_proj"
cat > "$mock_dir/claude" <<'MOCK'
#!/bin/bash
echo "mock result: $*"
MOCK
chmod +x "$mock_dir/claude"
export PATH="$mock_dir:$PATH"

job_id=$(
  ccs-dispatch --sync \
    --project "$test_proj" \
    "test task" 2>&1 \
  | grep -oP 'd-\d{8}-\d{6}-[a-f0-9]{4}' \
  | head -1
)
echo "Job: $job_id"

dispatch_dir="$(_ccs_dispatch_dir)"
if [ -f "$dispatch_dir/results/${job_id}.md" ]; then
  echo "PASS: result .md created"
else
  echo "FAIL: no result .md"
  exit 1
fi

status=$(
  _ccs_dispatch_jsonl_latest "$job_id" \
  | jq -r '.status'
)
if [ "$status" = "completed" ]; then
  echo "PASS: JSONL status completed"
else
  echo "FAIL: status=$status"
  exit 1
fi

echo ""
echo "=== Test 4: E2E dry-run (async) ==="
cat > "$mock_dir/claude" <<'MOCK'
#!/bin/bash
sleep 1
echo "async mock result: $*"
MOCK
chmod +x "$mock_dir/claude"

async_out=$(
  ccs-dispatch \
    --project "$test_proj" \
    "async test" 2>&1
)
async_id=$(echo "$async_out" | grep -oP 'd-\d{8}-\d{6}-[a-f0-9]{4}' | head -1)
echo "Async job: $async_id"

for i in $(seq 1 10); do
  sleep 1
  st=$(_ccs_dispatch_jsonl_latest "$async_id" \
    | jq -r '.status' 2>/dev/null)
  [ "$st" = "completed" ] && break
done
if [ "$st" = "completed" ]; then
  echo "PASS: async job completed"
else
  echo "FAIL: async status=$st"
fi

echo ""
echo "=== Test 5: timeout handling ==="
cat > "$mock_dir/claude" <<'MOCK'
#!/bin/bash
sleep 300
MOCK
chmod +x "$mock_dir/claude"

ccs-dispatch --sync --timeout 2 \
  --project "$test_proj" \
  "timeout test" >/dev/null 2>&1
to_id=$(grep '"status":"timeout"' \
  "$dispatch_dir/jobs.jsonl" \
  | jq -r '.job_id' | tail -1)
if [ -n "$to_id" ]; then
  echo "PASS: timeout detected"
else
  echo "FAIL: no timeout record"
fi

# Cleanup mock
rm -rf "$mock_dir" "$test_proj"
