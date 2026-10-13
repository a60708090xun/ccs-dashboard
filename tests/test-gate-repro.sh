#!/usr/bin/env bash
# tests/test-gate-repro.sh — every attempt records the facts needed to
# reproduce it (attempt-NN/repro.json: executor, model, cli_version, cwd_head).
#
# Drives the whole _ccs_dispatch_run chain with fake CLIs on PATH, because the
# record is written by _ccs_dispatch_run_one in front of the run_worker seam
# and an overridden seam would hide it. Every fake handles `--version` on its
# first line (prints, exits, no argv log, no side effect); the one exception is
# the marker fake used by AC3.6, which exists to catch where --version runs.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-gate-repro-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-gate-repro"; rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/bin-failver" "$WORK/bin-marker" "$WORK/bin-wingman" \
  "$WORK/bin-twoline"
_TEST_DIRS+=("$WORK")
WORK="$(realpath "$WORK")"

# Main fake claude/gemini. Non-version calls are counted in FAKE_STATE (one
# state file per CLI name). FAKE_COMMIT_FIRST=1 makes the first real call commit
# in $PWD; the second real call writes done.txt so an AC can go FAIL -> PASS.
for c in claude gemini; do
  cat > "$WORK/bin/$c" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  v="FAKE_VERSION_${0##*/}"; echo "${!v:-0.0.0}"; exit 0
fi
n=0; [ -f "$FAKE_STATE" ] && n="$(cat "$FAKE_STATE")"
n=$((n + 1)); echo "$n" > "$FAKE_STATE"
if [ "$n" -eq 1 ] && [ -n "${FAKE_COMMIT_FIRST:-}" ]; then
  git -c user.email=w@t -c user.name=w commit -q --allow-empty -m "worker commit"
fi
[ "$n" -ge 2 ] && : > done.txt
exit 0
FAKE
  chmod +x "$WORK/bin/$c"
done

# --version fails (exit 1) after printing something that must not be kept.
cat > "$WORK/bin-failver/claude" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "should-not-be-recorded"; exit 1; fi
exit 0
FAKE
chmod +x "$WORK/bin-failver/claude"

# Marker fake: --version drops a marker in $PWD (the only fake that does).
cat > "$WORK/bin-marker/claude" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then : > "$PWD/ver-marker"; echo "7.7.7"; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/bin-marker/claude"

# Fake wingman: logs every call, so a --version probe would be visible.
cat > "$WORK/bin-wingman/wingman" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_WINGMAN_LOG"
mkdir -p .wingman
printf 'overall_status: done\n' > .wingman/result.md
exit 0
FAKE
chmod +x "$WORK/bin-wingman/wingman"

# Fake opencode: only needs to answer --version for the repro probe.
cat > "$WORK/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "5.5.5"; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/bin/opencode"

ORIG_PATH="$PATH"
export PATH="$WORK/bin:$ORIG_PATH"
export FAKE_WINGMAN_LOG="$WORK/wingman.log"

# mk_repo <name> [nocommit] -> path of a git repo (with one commit by default)
mk_repo() {
  local d="$WORK/repo-$1"; rm -rf "$d"; mkdir -p "$d"
  (cd "$d" && git init -q)
  [ "${2:-}" = "nocommit" ] || (cd "$d" && echo x > f.txt && git add f.txt \
    && git -c user.email=t@t -c user.name=t commit -qm init)
  echo "$d"
}

# mk_task <name> <cwd> <extra top-level yaml lines> <ac cmd> <loop_budget>
mk_task() {
  local f="$WORK/$1.task.yaml"
  {
    echo "id: rp-$1"
    echo "goal: g"
    [ -n "$3" ] && printf '%s\n' "$3"
    echo "scope:"
    echo "  cwd: $2"
    echo "execution_policy:"
    echo "  loop_budget: $5"
    echo "acceptance_criteria:"
    echo "  - id: AC1"
    echo "    text: t"
    echo "    verify:"
    echo "      cmd: \"$4\""
  } > "$f"
  echo "$f"
}

# run_task <task.yaml> -> hop dir of the run (FAKE_STATE reset per run)
run_task() {
  local chain
  export FAKE_STATE="$WORK/state-$(basename "$1" .task.yaml)"; rm -f "$FAKE_STATE"
  chain="$(_ccs_dispatch_run "$1")"
  ls -d "$chain"/hop-01-* | head -n1
}

head_of() { git -C "$1" rev-parse HEAD; }

echo "=== AC3.1: both attempts record all four keys ==="
repo="$(mk_repo a)"
y="$(mk_task a "$repo" $'executor: claude\nmodel: m1' 'test -f done.txt' 1)"
export FAKE_VERSION_claude="9.9.9 (Fake)" FAKE_VERSION_gemini="8.8.8"
hop="$(run_task "$y")"
assert_eq "two attempts ran" "2" "$(jq -r '.attempts' "$hop/final.json")"
for n in 01 02; do
  r="$hop/attempt-$n/repro.json"
  assert_eq "attempt-$n repro.json exists" "yes" "$([ -f "$r" ] && echo yes || echo no)"
  assert_eq "attempt-$n has exactly the four keys" \
    '["cli_version","cwd_head","executor","model"]' "$(jq -c 'keys' "$r")"
  assert_eq "attempt-$n cli_version" "9.9.9 (Fake)" "$(jq -r '.cli_version' "$r")"
  assert_eq "attempt-$n executor" "claude" "$(jq -r '.executor' "$r")"
  assert_eq "attempt-$n model" "m1" "$(jq -r '.model' "$r")"
done

echo "=== AC3.2: cwd_head is read per attempt ==="
repo="$(mk_repo b)"
h0="$(head_of "$repo")"
y="$(mk_task b "$repo" 'executor: claude' 'test -f done.txt' 1)"
export FAKE_COMMIT_FIRST=1
hop="$(run_task "$y")"
unset FAKE_COMMIT_FIRST
h1="$(head_of "$repo")"
assert_eq "worker really committed (HEAD moved)" "different" \
  "$([ "$h0" != "$h1" ] && echo different || echo same)"
assert_eq "attempt-01 cwd_head is the initial HEAD" "$h0" \
  "$(jq -r '.cwd_head' "$hop/attempt-01/repro.json")"
assert_eq "attempt-02 cwd_head is the post-commit HEAD" "$h1" \
  "$(jq -r '.cwd_head' "$hop/attempt-02/repro.json")"

echo "=== AC3.3: the three null cases ==="
repo="$(mk_repo c nocommit)"
y="$(mk_task c "$repo" 'executor: claude' 'true' 0)"
hop="$(run_task "$y")"
r="$hop/attempt-01/repro.json"
assert_eq "no-commit repo: cwd_head is null, not the literal HEAD" "null" \
  "$(jq -c '.cwd_head' "$r")"
assert_eq "undeclared model: model is null" "null" "$(jq -c '.model' "$r")"
assert_eq "control: version still read" "9.9.9 (Fake)" "$(jq -r '.cli_version' "$r")"

repo="$(mk_repo c2)"
y="$(mk_task c2 "$repo" 'executor: claude' 'true' 0)"
hop="$(PATH="$WORK/bin-failver:$PATH" run_task "$y")"
r="$hop/attempt-01/repro.json"
assert_eq "--version exit 1: cli_version is null (output discarded)" "null" \
  "$(jq -c '.cli_version' "$r")"
assert_eq "control: cwd_head still read" "$(head_of "$repo")" \
  "$(jq -r '.cwd_head' "$r")"

echo "=== AC3.4: gemini maps to the gemini CLI ==="
repo="$(mk_repo d)"
y="$(mk_task d "$repo" 'executor: gemini' 'true' 0)"
hop="$(run_task "$y")"
r="$hop/attempt-01/repro.json"
assert_eq "gemini cli_version" "8.8.8" "$(jq -r '.cli_version' "$r")"
assert_eq "gemini executor" "gemini" "$(jq -r '.executor' "$r")"

echo "=== opencode maps to the opencode CLI ==="
repo="$(mk_repo oc)"
y="$(mk_task oc "$repo" 'executor: opencode' 'true' 0)"
hop="$(run_task "$y")"
r="$hop/attempt-01/repro.json"
assert_eq "opencode cli_version" "5.5.5" "$(jq -r '.cli_version' "$r")"
assert_eq "opencode executor" "opencode" "$(jq -r '.executor' "$r")"

echo "=== AC3.5: wingman is never probed ==="
repo="$(mk_repo e)"
echo "plan" > "$WORK/plan.md"
y="$(mk_task e "$repo" $'executor: wingman\nplan: "plan.md"' 'true' 0)"
: > "$FAKE_WINGMAN_LOG"
hop="$(PATH="$WORK/bin-wingman:$PATH" run_task "$y")"
r="$hop/attempt-01/repro.json"
assert_eq "wingman cli_version is null" "null" "$(jq -c '.cli_version' "$r")"
assert_eq "wingman executor" "wingman" "$(jq -r '.executor' "$r")"
assert_eq "wingman was called once (execute only, no --version probe)" "1" \
  "$(wc -l < "$FAKE_WINGMAN_LOG")"
assert_not_contains "no --version in wingman argv log" \
  "$(cat "$FAKE_WINGMAN_LOG")" "--version"
bash "$SCRIPT_DIR/tests/test-gate-wingman.sh" >/dev/null 2>&1
assert_eq "existing test-gate-wingman.sh stays green" "0" "$?"

echo "=== AC3.6: --version runs in hop_dir, not scope.cwd ==="
repo="$(mk_repo f)"
y="$(mk_task f "$repo" 'executor: claude' 'true' 0)"
hop="$(PATH="$WORK/bin-marker:$PATH" run_task "$y")"
assert_eq "control: marker fake ran --version (marker in hop_dir)" "yes" \
  "$([ -e "$hop/ver-marker" ] && echo yes || echo no)"
assert_eq "scope.cwd has no marker" "no" \
  "$([ -e "$repo/ver-marker" ] && echo yes || echo no)"
assert_eq "control: marker fake's version was recorded" "7.7.7" \
  "$(jq -r '.cli_version' "$hop/attempt-01/repro.json")"

echo "=== cli_version keeps only the first line of --version ==="
cat > "$WORK/bin-twoline/claude" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf '6.6.6 (Two)\nbuild extra\n'; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/bin-twoline/claude"
repo="$(mk_repo g)"
y="$(mk_task g "$repo" 'executor: claude' 'true' 0)"
hop="$(PATH="$WORK/bin-twoline:$PATH" run_task "$y")"
assert_eq "two-line --version: first line only" "6.6.6 (Two)" \
  "$(jq -r '.cli_version' "$hop/attempt-01/repro.json")"

test_summary
