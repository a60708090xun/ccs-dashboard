#!/usr/bin/env bash
# tests/test-skills-install.sh
# Run: bash tests/test-skills-install.sh
#
# Contract for skills/install.sh (issue #103): a cheap, idempotent rebuild
# entry point for the ~/.claude/skills/ links this repo owns. The config-layer
# sync mirrors that directory with `rsync --delete` and calls this script at the
# end of every push, so the shapes below are not hypothetical — a deleted link
# is what the mirror actually does, and a dangling one is what a moved checkout
# leaves behind. Both make the skill invisible to Claude Code while the repo
# content stays perfectly intact, which is why it went unnoticed for two months.
#
# Runs against a throwaway HOME, so it never touches the real ~/.claude/skills/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tests/fixture-helper.sh"

INSTALLER="$ROOT/skills/install.sh"
SKILLS=(ccs-dispatch-run ccs-orchestrator)

setup_test_dir "skills-install"
FAKE_HOME="$TEST_DIR/home"
SKILL_DIR="$FAKE_HOME/.claude/skills"
mkdir -p "$FAKE_HOME"

# Results land in globals rather than on stdout: `x=$(run_installer)` would run
# the function in a subshell, where the exit code it recorded dies with it.
LAST_RC=0
LAST_OUT=""
run_installer() {
  local rc=0
  LAST_OUT=$(HOME="$FAKE_HOME" bash "$INSTALLER" "$@" 2>&1) || rc=$?
  LAST_RC=$rc
}

# resolves | dangling | missing | not-a-link
# Second argument overrides the skills dir, for the top-level-installer case
# that needs its own throwaway HOME.
link_state() {
  local p="${2:-$SKILL_DIR}/$1"
  if [ -L "$p" ]; then
    [ -e "$p" ] && echo "resolves" || echo "dangling"
  elif [ -e "$p" ]; then
    echo "not-a-link"
  else
    echo "missing"
  fi
}

# ── 1. Fresh install links every skill ──
run_installer; out="$LAST_OUT"
assert_eq "fresh install exits 0" "0" "$LAST_RC"
for s in "${SKILLS[@]}"; do
  assert_eq "fresh install: $s resolves" "resolves" "$(link_state "$s")"
  assert_eq "fresh install: $s points at this repo" \
    "$(readlink -f "$ROOT/skills/$s")" "$(readlink -f "$SKILL_DIR/$s")"
done

# ── 2. Re-running changes nothing ──
run_installer; out="$LAST_OUT"
assert_eq "second run exits 0" "0" "$LAST_RC"
assert_eq "second run touches nothing" \
  "${#SKILLS[@]}" "$(printf '%s\n' "$out" | grep -c 'already points correctly')"
assert_not_contains "second run creates no link" "$out" "Installed:"
assert_not_contains "second run repairs nothing" "$out" "Repaired:"

# ── 3. A deleted link (what `rsync --delete` does) comes back ──
rm "$SKILL_DIR/ccs-orchestrator"
run_installer; out="$LAST_OUT"
assert_eq "deleted link restored" "resolves" "$(link_state ccs-orchestrator)"
assert_contains "restore is reported" "$out" "Installed:"
assert_eq "restore leaves the other link alone" \
  "1" "$(printf '%s\n' "$out" | grep -c 'already points correctly')"

# ── 4. A dangling link is repaired ──
# The failure the old top-level installer could not fix: it skipped on `-L`
# alone, so a link pointing nowhere survived every re-run.
ln -sfn "$TEST_DIR/gone" "$SKILL_DIR/ccs-orchestrator"
assert_eq "precondition: link dangles" "dangling" "$(link_state ccs-orchestrator)"
run_installer; out="$LAST_OUT"
assert_eq "dangling link repaired" "resolves" "$(link_state ccs-orchestrator)"
assert_contains "repair is reported" "$out" "Repaired:"

# ── 5. A link pointing at the wrong place is repaired ──
mkdir -p "$TEST_DIR/other-clone/ccs-orchestrator"
ln -sfn "$TEST_DIR/other-clone/ccs-orchestrator" "$SKILL_DIR/ccs-orchestrator"
run_installer; out="$LAST_OUT"
assert_eq "misdirected link repointed at this repo" \
  "$(readlink -f "$ROOT/skills/ccs-orchestrator")" \
  "$(readlink -f "$SKILL_DIR/ccs-orchestrator")"
assert_contains "repoint is reported" "$out" "Repaired:"

# ── 6. A real directory in the way is reported, never clobbered ──
rm "$SKILL_DIR/ccs-orchestrator"
mkdir -p "$SKILL_DIR/ccs-orchestrator"
echo "the only copy" > "$SKILL_DIR/ccs-orchestrator/SKILL.md"
run_installer; out="$LAST_OUT"
assert_eq "occupied path fails the run" "1" "$LAST_RC"
assert_contains "occupied path warns" "$out" "is not a symlink"
assert_eq "occupied path left as a directory" "not-a-link" \
  "$(link_state ccs-orchestrator)"
assert_eq "occupant content untouched" "the only copy" \
  "$(cat "$SKILL_DIR/ccs-orchestrator/SKILL.md")"
rm -rf "$SKILL_DIR/ccs-orchestrator"
run_installer

# ── 7. --uninstall removes our links ──
run_installer --uninstall; out="$LAST_OUT"
assert_eq "uninstall exits 0" "0" "$LAST_RC"
for s in "${SKILLS[@]}"; do
  assert_eq "uninstall removed $s" "missing" "$(link_state "$s")"
done

# ── 8. --uninstall leaves another clone's link alone ──
run_installer
ln -sfn "$TEST_DIR/other-clone/ccs-orchestrator" "$SKILL_DIR/ccs-orchestrator"
run_installer --uninstall; out="$LAST_OUT"
assert_contains "foreign link kept" "$out" "points elsewhere"
assert_eq "foreign link still there" "resolves" "$(link_state ccs-orchestrator)"
assert_eq "our own link still removed" "missing" "$(link_state ccs-dispatch-run)"

# ── 9. An unknown option is rejected, not treated as install ──
run_installer --frobnicate; out="$LAST_OUT"
assert_eq "unknown option exits 2" "2" "$LAST_RC"
assert_eq "unknown option installs nothing" "missing" \
  "$(link_state ccs-dispatch-run)"

# ── 10. A skill missing its SKILL.md is reported and fails the run ──
# The shape when a skill is renamed or dropped while its name stays in SKILLS:
# nothing links it, and the exit code is the only thing that tells the caller.
# Exercised against a copy of the installer, so the repo's own skills stay put.
FAKE_SKILLS="$TEST_DIR/fake-skills"
mkdir -p "$FAKE_SKILLS/ccs-orchestrator" "$FAKE_SKILLS/ccs-dispatch-run"
cp "$INSTALLER" "$FAKE_SKILLS/install.sh"
echo "stub" > "$FAKE_SKILLS/ccs-orchestrator/SKILL.md"  # ccs-dispatch-run: none
rm -f "$SKILL_DIR/ccs-orchestrator" "$SKILL_DIR/ccs-dispatch-run"
fake_rc=0
fake_out=$(HOME="$FAKE_HOME" bash "$FAKE_SKILLS/install.sh" 2>&1) || fake_rc=$?
assert_eq "missing SKILL.md fails the run" "1" "$fake_rc"
assert_contains "missing SKILL.md is reported" "$fake_out" "SKILL.md missing"
assert_eq "the healthy skill is still linked" "resolves" \
  "$(link_state ccs-orchestrator)"
assert_eq "the broken skill is not linked" "missing" \
  "$(link_state ccs-dispatch-run)"

# ── 11. The top-level installer reaches this script (issue #103 AC 4) ──
# Without this case, deleting the delegation block from install.sh leaves the
# whole suite green while both skills silently stop being linked — the exact
# failure mode this work exists to close. Needs its own HOME: the top-level
# installer appends to ~/.bashrc, and XDG_DATA_HOME is pinned so its uninstall
# cannot reach the real data directory.
if command -v jq >/dev/null 2>&1; then
  TOP_HOME="$TEST_DIR/top-home"
  TOP_SKILLS="$TOP_HOME/.claude/skills"
  mkdir -p "$TOP_HOME"
  top_rc=0
  HOME="$TOP_HOME" XDG_DATA_HOME="$TOP_HOME/.local/share" \
    bash "$ROOT/install.sh" >/dev/null 2>&1 || top_rc=$?
  assert_eq "top-level install exits 0" "0" "$top_rc"
  for s in "${SKILLS[@]}"; do
    assert_eq "top-level install linked $s" "resolves" \
      "$(link_state "$s" "$TOP_SKILLS")"
  done

  top_rc=0
  HOME="$TOP_HOME" XDG_DATA_HOME="$TOP_HOME/.local/share" \
    bash "$ROOT/install.sh" --uninstall >/dev/null 2>&1 || top_rc=$?
  assert_eq "top-level uninstall exits 0" "0" "$top_rc"
  for s in "${SKILLS[@]}"; do
    assert_eq "top-level uninstall removed $s" "missing" \
      "$(link_state "$s" "$TOP_SKILLS")"
  done
else
  echo "  SKIP: jq missing, top-level installer not exercised"
fi

test_summary
