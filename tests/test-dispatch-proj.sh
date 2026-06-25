#!/usr/bin/env bash
# Tests for _ccs_dispatch_resolve_proj_from_dir — map an absolute
# project_dir to the lead-side proj key for the inbound .md (Stage 2).
# ccs keeps its OWN map (CCS_DISPATCH_PROJ_MAP, format "key = abspath",
# mirroring the lead whitelist) and never reads the lead's file.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/ccs-dispatch.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

MAP="$(mktemp "$SCRIPT_DIR/tmp.projmap.XXXXXX")"
cat > "$MAP" <<'EOF'
# ccs proj map (key = abspath, mirrors lead whitelist keys)
demo = /pool2/chenhsun/tools/ccs-dashboard
other = /home/x/work/other
EOF
export CCS_DISPATCH_PROJ_MAP="$MAP"
cleanup() { rm -f "$MAP"; }
trap cleanup EXIT

test_exact_match() {
  local got; got="$(_ccs_dispatch_resolve_proj_from_dir /pool2/chenhsun/tools/ccs-dashboard)"
  [ "$got" = "demo" ] && ok "exact path -> key" || bad "exact (got: '$got')"
}
test_trailing_slash() {
  local got; got="$(_ccs_dispatch_resolve_proj_from_dir /pool2/chenhsun/tools/ccs-dashboard/)"
  [ "$got" = "demo" ] && ok "trailing slash normalized" || bad "trailing slash (got: '$got')"
}
test_second_entry() {
  local got; got="$(_ccs_dispatch_resolve_proj_from_dir /home/x/work/other)"
  [ "$got" = "other" ] && ok "second entry resolves" || bad "second (got: '$got')"
}
test_no_match() {
  _ccs_dispatch_resolve_proj_from_dir /no/such/dir >/dev/null 2>&1 \
    && bad "no match should fail" || ok "no match -> rc!=0"
}
test_missing_map() {
  ( export CCS_DISPATCH_PROJ_MAP=/no/such/map
    _ccs_dispatch_resolve_proj_from_dir /pool2/chenhsun/tools/ccs-dashboard >/dev/null 2>&1 ) \
    && bad "missing map should fail" || ok "missing map -> rc!=0"
}

run() {
  test_exact_match
  test_trailing_slash
  test_second_entry
  test_no_match
  test_missing_map
  printf '\n--- %d passed, %d failed ---\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
run
