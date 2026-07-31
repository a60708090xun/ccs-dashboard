#!/usr/bin/env bash
# tests/test-process-scan-scope.sh
# Run: bash tests/test-process-scan-scope.sh
#
# Invariant: every process enumeration in this repo is scoped to the invoking
# EUID. On a shared host an unscoped scan reads other accounts' claude/gemini
# processes, and the tool then treats them as the caller's own (issue #101:
# wrong session-liveness verdicts, a cleanup summary reporting memory it never
# freed, and stats counting strangers).
#
# This is a STATIC check, not a behavioural one. Reproducing the bug needs a
# second account running claude, which is not available in CI or on a dev box,
# and the failure it guards against is a NEW call site written unscoped -- the
# actual way this bug recurs. It also catches unscoped scans whose result is
# discarded, which no behavioural test can see (one such dead scan existed in
# ccs-overview.sh and was removed with this test).
#
# Allowed: `ps -u <uid>`, `ps -p <pid>` (pid already from a scoped source),
# `pgrep -u <uid>`. Forbidden: an all-process selector (`-e`, `-A`, `aux`,
# `ax`) or a `pgrep` with no `-u`/`-U`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tests/fixture-helper.sh"

# An all-process `ps` selector, or a pgrep with no user filter. Comment lines
# are stripped by the caller: prose about `pgrep -x` is not a call site.
BAD_PS_RE='(^|[^[:alnum:]_-])ps[[:space:]]+(-[[:alpha:]]*[eA][[:alpha:]]*|aux|ax)([^[:alnum:]]|$)'
BAD_PGREP_RE='(^|[^[:alnum:]_-])pgrep([[:space:]]+-[^uU[:space:]]+)*[[:space:]]'

scan_file() {
  local f="$1" out=""
  # Drop whole-line comments before matching.
  local body; body=$(grep -vE '^[[:space:]]*#' "$f" || true)
  out=$(printf '%s\n' "$body" | grep -nE "$BAD_PS_RE" || true)
  printf '%s' "$out"
  out=$(printf '%s\n' "$body" | grep -nE "$BAD_PGREP_RE" \
        | grep -vE '\-[uU][[:space:]]' || true)
  printf '%s' "$out"
}

# ── 1. The detector itself must work (guards against a rotted regex) ──
_probe() {
  local tmp; tmp=$(mktemp "$ROOT/tmp/scan-probe.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  local hit; hit=$(scan_file "$tmp")
  rm -f "$tmp"
  [ -n "$hit" ] && echo "detected" || echo "clean"
}
mkdir -p "$ROOT/tmp"
assert_eq "detector flags ps -eo"        "detected" "$(_probe 'x=$(ps -eo pid,comm)')"
assert_eq "detector flags ps aux"        "detected" "$(_probe 'n=$(ps aux | grep -c x)')"
assert_eq "detector flags ps -A"         "detected" "$(_probe 'ps -A -o args')"
assert_eq "detector flags bare pgrep"    "detected" "$(_probe 'pgrep -x claude')"
assert_eq "detector allows ps -u"        "clean"    "$(_probe 'ps -u "$(id -u)" -o pid,comm')"
assert_eq "detector allows ps -p"        "clean"    "$(_probe 'ps -p "$pid" -o lstart=')"
assert_eq "detector allows pgrep -u"     "clean"    "$(_probe 'pgrep -u "$_uid" -x claude')"
assert_eq "detector ignores comments"    "clean"    "$(_probe '# count source (pgrep -x) never misses')"

# ── 2. No unscoped scan anywhere in the shipped sources ──
offenders=""
for f in ccs-*.sh install.sh skills/install.sh *.py; do
  [ -f "$f" ] || continue
  hits=$(scan_file "$f")
  [ -n "$hits" ] && offenders="${offenders}${f}: ${hits}"$'\n'
done
assert_eq "no unscoped process enumeration in shipped sources" "" "$offenders"

test_summary
