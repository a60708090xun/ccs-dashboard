#!/usr/bin/env bash
# tests/test-dispatch-evidence-base.sh — attempt evidence is anchored at the
# hop's base commit, so a worker cannot empty it by staging (issue #109).
#
# What the old bare `git diff` cost: Stage 2 is allowed to read only
# diff.patch / git-status.txt / verdict.json, and a worker that ran `git add`
# left diff.patch empty -- indistinguishable from a worker that did nothing.
# The worker runs auto-approved and nothing forbids it from staging or
# committing, so this cannot be left to worker discipline.
#
# The negative control matters as much as the positive cases: an evidence path
# that is non-empty no matter what the worker did would pass every assertion
# below except that one, while telling Stage 2 nothing.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-evidence-base-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-evidence-base"; rm -rf "$WORK"
mkdir -p "$WORK/repo" "$WORK/bin"; _TEST_DIRS+=("$WORK")

# Fake claude on PATH (precedent: test-gate-worker-error.sh). FAKE_CLI_MODE
# selects what the "worker" does to the repo, which is the whole variable under
# test -- the real executor's behaviour here is unconstrained.
cat > "$WORK/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cd "$FAKE_REPO" || exit 1
case "${FAKE_CLI_MODE:-none}" in
  edit)     printf 'worker line\n' >> tracked.txt ;;
  stage)    printf 'worker line\n' >> tracked.txt; git add tracked.txt ;;
  commit)   printf 'worker line\n' >> tracked.txt; git add tracked.txt
            git -c user.email=w@t -c user.name=w commit -qm "worker commit" ;;
  new)      printf 'brand new\n' > untracked.txt ;;
  none)     : ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

CWD="$WORK/repo"; export FAKE_REPO="$CWD"
(cd "$CWD" && git init -q \
  && printf 'base line\n' > tracked.txt \
  && git add tracked.txt \
  && git -c user.email=t@t -c user.name=t commit -qm base)
BASE="$(cd "$CWD" && git rev-parse HEAD)"

HOP="$WORK/hop"; mkdir -p "$HOP"
printf '%s\n' "$BASE" > "$HOP/base-commit"

# spawn <attempt> <mode> -> attempt dir. Restores the repo to the base commit
# first, so each case starts from the same world.
spawn() {
  local attempt="$1" mode="$2"
  (cd "$CWD" && git reset -q --hard "$BASE" && git clean -qfd)
  export FAKE_CLI_MODE="$mode"
  _ccs_dispatch_run_worker "$CWD" "do X" "$HOP" "$attempt" 60 claude
  printf '%s\n' "$HOP/attempt-$(printf '%02d' "$attempt")"
}

echo "=== a staged edit stays visible in evidence (the reported bug) ==="
ad="$(spawn 1 stage)"
assert_eq "the stub really staged (otherwise this proves nothing)" "yes" \
  "$( (cd "$CWD" && git diff --quiet) && echo yes || echo no )"
assert_contains "staged edit appears in diff.patch" \
  "$(cat "$ad/diff.patch")" "worker line"

echo "=== a committed edit stays visible (only base-anchoring passes this) ==="
ad="$(spawn 2 commit)"
assert_eq "the stub really committed" "yes" \
  "$( (cd "$CWD" && git diff HEAD --quiet) && echo yes || echo no )"
assert_contains "committed edit appears in diff.patch" \
  "$(cat "$ad/diff.patch")" "worker line"

echo "=== an unstaged edit still works (no regression) ==="
ad="$(spawn 3 edit)"
assert_contains "unstaged edit appears in diff.patch" \
  "$(cat "$ad/diff.patch")" "worker line"

echo "=== negative control: a worker that did nothing leaves it empty ==="
ad="$(spawn 4 none)"
assert_eq "diff.patch empty when the repo is untouched" "0" \
  "$(wc -c < "$ad/diff.patch" | tr -d ' ')"
assert_eq "git-status.txt empty too" "0" \
  "$(wc -c < "$ad/git-status.txt" | tr -d ' ')"

echo "=== a new file is untracked: status names it, diff cannot ==="
ad="$(spawn 5 new)"
assert_contains "untracked file visible in git-status.txt" \
  "$(cat "$ad/git-status.txt")" "?? untracked.txt"
assert_eq "diff.patch still empty for an untracked-only change" "0" \
  "$(wc -c < "$ad/diff.patch" | tr -d ' ')"

echo "=== no usable base: degrade to the old behaviour, do not crash ==="
NOBASE="$WORK/hop-nobase"; mkdir -p "$NOBASE"
(cd "$CWD" && git reset -q --hard "$BASE" && git clean -qfd)
export FAKE_CLI_MODE=edit
_ccs_dispatch_run_worker "$CWD" "do X" "$NOBASE" 1 60 claude
ad="$NOBASE/attempt-01"
assert_contains "unstaged edit still captured without base-commit" \
  "$(cat "$ad/diff.patch")" "worker line"
assert_eq "evidence files exist rather than aborting" "yes" \
  "$([ -f "$ad/git-status.txt" ] && echo yes || echo no)"

echo "=== a repo with no commit yet: still shows the work (found by review) ==="
# `git rev-parse HEAD` prints the literal string "HEAD" on stdout in a repo with
# no commit -- only the fatal goes to stderr. Recording that as the base fed an
# invalid revision to git diff, which failed into an empty patch: the very
# vacuous evidence this change exists to remove, and a regression against the
# bare `git diff` it replaced. Hence --verify, whose stdout is empty here.
FRESH="$WORK/fresh"; mkdir -p "$FRESH"
# tracked.txt, staged but never committed: the stub appends to that name, and a
# bare `git diff` only shows a path git already knows about.
(cd "$FRESH" && git init -q && printf 'base line\n' > tracked.txt \
  && git add tracked.txt)
FHOP="$WORK/hop-fresh"; mkdir -p "$FHOP"
printf '' > "$FHOP/base-commit"
FAKE_REPO="$FRESH" FAKE_CLI_MODE=edit \
  _ccs_dispatch_run_worker "$FRESH" "do X" "$FHOP" 1 60 claude
assert_contains "staged-but-uncommitted repo still yields a diff" \
  "$(cat "$FHOP/attempt-01/diff.patch")" "worker line"

echo "=== an unresolvable base degrades instead of emptying the diff ==="
# A worker may gc, re-init or switch away; a stale sha would make git diff fail
# into an empty patch. Re-verifying turns that into the no-base fallback.
GONE="$WORK/hop-gone"; mkdir -p "$GONE"
printf '%s\n' "0000000000000000000000000000000000000000" > "$GONE/base-commit"
(cd "$CWD" && git reset -q --hard "$BASE" && git clean -qfd)
export FAKE_CLI_MODE=edit
_ccs_dispatch_run_worker "$CWD" "do X" "$GONE" 1 60 claude
assert_contains "unresolvable base falls back to the bare diff" \
  "$(cat "$GONE/attempt-01/diff.patch")" "worker line"

echo "=== integration: run_one records the base before the first attempt ==="
# Without this the helper above would read a base-commit nobody writes, and the
# fix would be dead code in production while every unit case still passed.
cat > "$WORK/task.yaml" <<YAML
id: ev
goal: "touch a file"
scope: { cwd: "$CWD" }
acceptance_criteria:
  - id: AC1
    desc: "file changed"
    verify: { cmd: "git diff --quiet tracked.txt || true" }
YAML
(cd "$CWD" && git reset -q --hard "$BASE" && git clean -qfd)
SEEN_BASE=""
_ccs_dispatch_run_worker() {  # seam override: observe what run_one left us
  local hop="$3"
  SEEN_BASE="$(head -n1 "$hop/base-commit" 2>/dev/null)"
  mkdir -p "$hop/attempt-$(printf '%02d' "$4")"
  return 0
}
task_json="$(_ccs_dispatch_gate_load_task "$WORK/task.yaml")"
_ccs_dispatch_run_one "$task_json" "$WORK/task.yaml" "$WORK/hop-int" >/dev/null
assert_eq "run_one writes the hop's base commit before spawning" "$BASE" \
  "$SEEN_BASE"

# Same seam, no-commit repo: this is what pins --verify. A bare `git rev-parse
# HEAD` records the literal "HEAD" here, and every unit case above would still
# pass while production wrote an unusable anchor.
cat > "$WORK/task-fresh.yaml" <<YAML
id: evf
goal: "touch a file"
scope: { cwd: "$FRESH" }
acceptance_criteria:
  - id: AC1
    desc: "no-op"
    verify: { cmd: "true" }
YAML
SEEN_BASE="unset"
task_json="$(_ccs_dispatch_gate_load_task "$WORK/task-fresh.yaml")"
_ccs_dispatch_run_one "$task_json" "$WORK/task-fresh.yaml" \
  "$WORK/hop-int-fresh" >/dev/null
assert_eq "run_one records an empty base in a no-commit repo, not \"HEAD\"" "" \
  "$SEEN_BASE"

test_summary
