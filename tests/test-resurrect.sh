#!/usr/bin/env bash
# tests/test-resurrect.sh — _ccs_resurrect_prompt_archived unit tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-core.sh" 2>/dev/null || true

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 — expected '$2' got '$3'"; FAIL=$((FAIL+1)); }

echo "=== _ccs_resurrect_prompt_archived ==="

# ── Test 1: prompt-archived with live process → resurrected ──
_ccs_running_cwd_counts() { printf 'C:path-to-project\t1\n'; }
ROW1='C|/path/to/project|45|prompt-archived|\033[90m\033[9m|project|abc12345|45m ago|topic||/fake/path-to-project/abc12345.jsonl'
st1=$(printf '%s\n' "$ROW1" | _ccs_resurrect_prompt_archived | awk -F'|' '{print $4}')
case "$st1" in
  active|recent|idle|stale) pass "prompt-archived with live process → $st1" ;;
  *) fail "prompt-archived with live process resurrected" "active|idle|..." "$st1" ;;
esac

# ── Test 2: exit-archived passes through unchanged ──
_ccs_running_cwd_counts() { printf 'C:path-to-project\t1\n'; }
ROW2='C|/path/to/project|45|archived|\033[90m\033[9m|project|abc12346|45m ago|topic||/fake/path-to-project/abc12346.jsonl'
st2=$(printf '%s\n' "$ROW2" | _ccs_resurrect_prompt_archived | awk -F'|' '{print $4}')
[ "$st2" = "archived" ] && pass "exit-archived stays archived" \
                         || fail "exit-archived stays archived" "archived" "$st2"

# ── Test 3: prompt-archived without live process stays prompt-archived ──
_ccs_running_cwd_counts() { printf ''; }
ROW3='C|/path/to/project|45|prompt-archived|\033[90m\033[9m|project|abc12347|45m ago|topic||/fake/path-to-project/abc12347.jsonl'
st3=$(printf '%s\n' "$ROW3" | _ccs_resurrect_prompt_archived | awk -F'|' '{print $4}')
[ "$st3" = "prompt-archived" ] && pass "prompt-archived without process stays prompt-archived" \
                                || fail "prompt-archived without process stays prompt-archived" "prompt-archived" "$st3"

# ── Test 4: older prompt-archived loses slot to newer non-archived ──
_ccs_running_cwd_counts() { printf 'C:path-to-project\t1\n'; }
NEWER='C|/path/to/project|5|idle|\033[36m|project|newer001|5m ago|topic||/fake/path-to-project/newer001.jsonl'
OLDER='C|/path/to/project|120|prompt-archived|\033[90m\033[9m|project|older001|2h ago|topic||/fake/path-to-project/older001.jsonl'
out4=$(printf '%s\n%s\n' "$NEWER" "$OLDER" | _ccs_resurrect_prompt_archived)
newer_st=$(printf '%s\n' "$out4" | awk -F'|' '$7=="newer001"{print $4}')
older_st=$(printf '%s\n' "$out4" | awk -F'|' '$7=="older001"{print $4}')
[ "$newer_st" = "idle" ] && pass "newer non-archived keeps slot" \
                          || fail "newer non-archived keeps slot" "idle" "$newer_st"
[ "$older_st" = "prompt-archived" ] && pass "older prompt-archived without slot stays prompt-archived" \
                                    || fail "older prompt-archived without slot stays prompt-archived" "prompt-archived" "$older_st"

echo ""
echo "=== e2e: ccs_collect.py → resurrection → non-archived status ==="

TMPDIR_E2E=$(mktemp -d /pool2/chenhsun/tools/ccs-dashboard-fix-issue57/build/e2e-XXXXXX)
SID_E2E="aaaabbbb-cccc-dddd-eeee-ffffffffffff"
JDIR_E2E="$TMPDIR_E2E/projects/-tmp-ccs-e2e"
mkdir -p "$JDIR_E2E"
JFILE_E2E="$JDIR_E2E/${SID_E2E}.jsonl"
cat > "$JFILE_E2E" <<'JSONL'
{"type":"user","message":{"content":"hello"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
{"type":"last-prompt","timestamp":"2026-06-22T00:00:00Z"}
JSONL

raw=$(CCS_PROJECTS_DIR="$TMPDIR_E2E/projects" \
  python3 "$SCRIPT_DIR/ccs_collect.py" --file "$JFILE_E2E" | awk -F'|' '{print $4}')
[ "$raw" = "prompt-archived" ] \
  && pass "e2e: ccs_collect.py emits prompt-archived" \
  || fail "e2e: ccs_collect.py emits prompt-archived" "prompt-archived" "$raw"

_ccs_running_cwd_counts() {
  # Key is derived from the encoded dir name: basename "$(dirname "$_fp")" = -tmp-ccs-e2e → tmp-ccs-e2e
  local norm; norm=$(printf '%s' "-tmp-ccs-e2e" | sed 's/[\/._]/-/g; s/--*/-/g; s/^-//')
  printf 'C:%s\t1\n' "$norm"
}

resurrected=$(CCS_PROJECTS_DIR="$TMPDIR_E2E/projects" \
  python3 "$SCRIPT_DIR/ccs_collect.py" --file "$JFILE_E2E" \
  | _ccs_resurrect_prompt_archived \
  | awk -F'|' '{print $4}')
case "$resurrected" in
  active|recent|idle|stale) pass "e2e: session resurrected to '$resurrected'" ;;
  *) fail "e2e: session resurrected" "active|idle|..." "$resurrected" ;;
esac

rm -rf "$TMPDIR_E2E"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
