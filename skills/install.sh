#!/usr/bin/env bash
# skills/install.sh — link this repo's skills into ~/.claude/skills/
#
# Scope is deliberately narrow: symlinks only. No ~/.bashrc edit, no
# dependency check, no banner — those stay in the top-level install.sh, which
# calls this script so the linking logic has a single home.
#
# Why a separate entry point: a personal config layer mirrors ~/.claude/skills/
# with `rsync --delete`, which removes any symlink that repo does not own. The
# contract is that every repo creating a link there also offers a cheap,
# idempotent rebuild entry point for the sync flow to call at the end of each
# push. The top-level installer cannot serve that role — it appends to
# ~/.bashrc, checks dependencies and prints a banner, none of which belongs in
# a per-push step.
#
# Claude Code only. Claude Code does not read ~/.agents/skills/, so the link
# goes straight under ~/.claude/skills/. Making these two visible to Gemini CLI
# would need either an ~/.agents/skills/ entry or `gemini extensions link`;
# neither is done here, because nothing has asked for these skills from Gemini
# yet and both add per-push side effects outside ~/.claude/.
#
# Idempotent and safe to re-run.
#
# Usage:
#   ./skills/install.sh              Link skills (default)
#   ./skills/install.sh --uninstall  Remove links that point at this repo
#   ./skills/install.sh --help       Show usage

set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BASE="$HOME/.claude/skills"
SKILLS=(ccs-dispatch-run ccs-orchestrator)

fail_count=0

usage() {
  echo "Usage: $0 [--uninstall|--help]"
  echo
  echo "  (no args)     Link ${#SKILLS[@]} skills into ${TARGET_BASE}"
  echo "  --uninstall   Remove links pointing at this repo"
  echo
  echo "Skills: ${SKILLS[*]}"
}

link_one() {
  local name="$1"
  local src="$SKILLS_DIR/$name"
  local target="$TARGET_BASE/$name"

  if [ ! -f "$src/SKILL.md" ]; then
    echo "ERROR: $src/SKILL.md missing, skipping $name"
    fail_count=$((fail_count + 1))
    return
  fi

  if [ -L "$target" ]; then
    # The path comparison alone already catches a dangling link: `readlink -f`
    # resolves all but the last component, so a link pointing nowhere reports
    # its missing target rather than $src — which the SKILL.md check above has
    # just proved exists. The -e test is therefore defensive, not load-bearing;
    # it starts mattering only if that check is ever relaxed to tolerate a
    # missing $src. Verified by differential: without it, 11 target states
    # (live, dangling, deep-dangling, wrong target, self-loop, chained, real
    # file, real dir, ...) behave identically.
    if [ -e "$target" ] &&
       [ "$(readlink -f "$target")" = "$(readlink -f "$src")" ]; then
      echo "OK: $target already points correctly"
      return
    fi
    ln -sfn "$src" "$target"
    echo "Repaired: $target -> $src"
    return
  fi

  if [ -e "$target" ]; then
    # A real file or directory of that name may hold the only copy of
    # something. Report it, never clobber it.
    echo "WARN: $target exists and is not a symlink, left untouched"
    fail_count=$((fail_count + 1))
    return
  fi

  ln -s "$src" "$target"
  echo "Installed: $target -> $src"
}

unlink_one() {
  local name="$1"
  local src="$SKILLS_DIR/$name"
  local target="$TARGET_BASE/$name"

  if [ -L "$target" ]; then
    # Only remove a link that resolves to this checkout: the same skill name
    # may be served from another clone on the same machine.
    if [ "$(readlink -f "$target")" = "$(readlink -f "$src")" ]; then
      rm "$target"
      echo "Removed: $target"
    else
      echo "Kept: $target points elsewhere ($(readlink "$target"))"
    fi
  elif [ -e "$target" ]; then
    echo "WARN: $target is not a symlink, left untouched"
  fi
}

case "${1:-}" in
  --uninstall)
    for skill in "${SKILLS[@]}"; do unlink_one "$skill"; done
    ;;
  --help | -h)
    usage
    ;;
  "")
    mkdir -p "$TARGET_BASE"
    for skill in "${SKILLS[@]}"; do link_one "$skill"; done
    ;;
  *)
    echo "Unknown option: $1"
    usage
    exit 2
    ;;
esac

# A skill left unlinked means the link chain is incomplete; say so with the
# exit code, so a caller (the sync flow, or the top-level installer) can see it.
[ "$fail_count" -eq 0 ] || exit 1
