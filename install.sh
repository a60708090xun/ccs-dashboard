#!/usr/bin/env bash
# install.sh — Install/uninstall ccs-dashboard
# Usage:
#   ./install.sh              Install (add source line to ~/.bashrc)
#   ./install.sh --uninstall  Remove source line from ~/.bashrc
#   ./install.sh --check      Check dependencies and installation status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_LINE="source \"${SCRIPT_DIR}/ccs-dashboard.sh\""
BASHRC="$HOME/.bashrc"

# ── Colors ──
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

ok()   { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$1"; }
fail() { printf "${RED}✗${RESET} %s\n" "$1"; }

# ── Check dependencies ──
check_deps() {
  local missing=0

  # Linux platform check
  if [[ "$(uname -s)" == "Linux" ]]; then
    ok "Platform: Linux"
  else
    warn "Non-Linux platform detected ($(uname -s)) — currently only Linux/WSL is tested"
  fi

  # bash 4+ (for associative arrays, mapfile)
  local bash_ver="${BASH_VERSINFO[0]}"
  if [ "$bash_ver" -ge 4 ]; then
    ok "bash ${BASH_VERSION}"
  else
    fail "bash 4+ required (found ${BASH_VERSION})"
    missing=$((missing + 1))
  fi

  # jq
  if command -v jq &>/dev/null; then
    ok "jq $(jq --version 2>&1 | head -1)"
  else
    fail "jq not found — install: sudo apt install jq"
    missing=$((missing + 1))
  fi

  # less (for ccs-details interactive viewer)
  if command -v less &>/dev/null; then
    ok "less"
  else
    warn "less not found — ccs-details Enter view won't work"
  fi

  # Optional: xclip for --copy
  if command -v xclip &>/dev/null; then
    ok "xclip (for ccs-resume-prompt --copy)"
  elif command -v xsel &>/dev/null; then
    ok "xsel (for ccs-resume-prompt --copy)"
  else
    warn "xclip/xsel not found — ccs-resume-prompt --copy won't work"
  fi

  # jinja2 (for ccs-review HTML rendering)
  if python3 -c "import jinja2" 2>/dev/null; then
    ok "jinja2 $(python3 -c 'import jinja2; print(jinja2.__version__)')"
  else
    warn "jinja2 not found — optional, for ccs-review --format html"
    warn "  Install: pip3 install --user jinja2"
  fi

  # weasyprint (for ccs-review --format pdf)
  if python3 -c "import weasyprint" 2>/dev/null; then
    ok "weasyprint $(python3 -c 'import weasyprint; print(weasyprint.__version__)')"
  else
    warn "weasyprint not found — optional, for ccs-review --format pdf"
    warn "  Install: pip3 install --user weasyprint"
  fi

  # Check sessions dir exists
  local claude_sessions=0 gemini_sessions=0
  if [ -d "$HOME/.claude/projects" ]; then
    claude_sessions=$(find "$HOME/.claude/projects" -maxdepth 2 -name "*.jsonl" 2>/dev/null | wc -l)
  fi
  if [ -d "$HOME/.gemini" ]; then
    gemini_sessions=$(find "$HOME/.gemini" -name "*.json" 2>/dev/null | wc -l)
  fi

  if [ "$claude_sessions" -gt 0 ] || [ "$gemini_sessions" -gt 0 ]; then
    ok "Code CLI sessions: ${claude_sessions} (Claude) + ${gemini_sessions} (Gemini)"
  else
    warn "No Code CLI sessions found in ~/.claude or ~/.gemini"
  fi

  return "$missing"
}

# ── Check if already installed ──
is_installed() {
  grep -qF "ccs-dashboard.sh" "$BASHRC" 2>/dev/null
}

# ── Install ──
do_install() {
  echo "ccs-dashboard installer"
  echo "======================="
  echo

  # Check deps
  echo "Checking dependencies..."
  if ! check_deps; then
    echo
    fail "Missing required dependencies. Fix them and try again."
    exit 1
  fi
  echo

  # Check files exist
  local modules=(ccs-core.sh ccs-health.sh ccs-viewer.sh ccs-handoff.sh ccs-overview.sh ccs-feature.sh ccs-ops.sh ccs-dispatch.sh ccs-review.sh ccs-project.sh ccs-dashboard.sh)
  local all_found=true
  for mod in "${modules[@]}"; do
    if [ ! -f "${SCRIPT_DIR}/${mod}" ]; then
      fail "${mod} not found in ${SCRIPT_DIR}"
      all_found=false
    fi
  done
  if ! $all_found; then exit 1; fi
  ok "Script files found (${#modules[@]} modules)"

  # Syntax check
  local syntax_ok=true
  for mod in "${modules[@]}"; do
    if ! bash -n "${SCRIPT_DIR}/${mod}"; then
      fail "Syntax error in ${mod}"
      syntax_ok=false
    fi
  done
  if ! $syntax_ok; then exit 1; fi
  ok "Syntax check passed"

  # Add to .bashrc (idempotent)
  if is_installed; then
    warn "Already installed in ${BASHRC}"
  else
    echo "" >> "$BASHRC"
    echo "# ccs-dashboard — Code CLI Session management tools" >> "$BASHRC"
    echo "${SOURCE_LINE}" >> "$BASHRC"
    ok "Added to ${BASHRC}"
  fi

  # Install skill symlink (idempotent)
  local skill_src="${SCRIPT_DIR}/skills/ccs-orchestrator"
  local skill_dst="$HOME/.claude/skills/ccs-orchestrator"
  if [ -d "$skill_src" ]; then
    if [ -L "$skill_dst" ]; then
      warn "Skill symlink already exists: ${skill_dst}"
    elif [ -e "$skill_dst" ]; then
      warn "Skill path exists but is not a symlink: ${skill_dst} — skipping"
    else
      mkdir -p "$HOME/.claude/skills"
      ln -s "$skill_src" "$skill_dst"
      ok "Skill symlink: ${skill_dst} → ${skill_src}"
    fi
  fi

  echo
  echo "Done! Run 'source ~/.bashrc' or open a new terminal."
  echo
  echo "Commands available:"
  echo "  ccs (ccs-status)    — unified dashboard"
  echo "  ccs-sessions        — list sessions"
  echo "  ccs-active          — list open sessions"
  echo "  ccs-cleanup         — kill zombie processes"
  echo "  ccs-details         — interactive conversation browser"
  echo "  ccs-pick N          — show session details"
  echo "  ccs-html            — HTML dashboard"
  echo "  ccs-handoff         — generate handoff note"
  echo "  ccs-resume-prompt   — generate bootstrap prompt"
  echo "  ccs-overview        — cross-session work overview"
  echo "  ccs-feature         — feature progress tracking"
  echo "  ccs-tag             — manual session-to-feature assignment"
  echo "  ccs-recap           — daily work recap"
  echo "  ccs-crash           — detect crash-interrupted sessions"
  echo "  ccs-checkpoint      — progress snapshot (done/wip/blocked)"
  echo "  ccs-health          — session health detection"
  echo "  ccs-dispatch        — dispatch task to Code CLI (Claude Code)"
  echo "  ccs-jobs            — view dispatch job history"
  echo "  ccs-review          — session review report (md/html/pdf)"
  echo "  ccs-project         — per-project insight report (md/html)"
  echo
  echo "Skills installed:"
  echo "  ccs-orchestrator    — interactive work orchestrator (Code CLI skill)"
}

# ── Uninstall ──
do_uninstall() {
  if ! is_installed; then
    warn "Not installed in ${BASHRC}"
    return 0
  fi

  # Remove the source line and its comment
  sed -i '/# ccs-dashboard/d; /ccs-dashboard\.sh/d' "$BASHRC"
  ok "Removed from ${BASHRC}"

  # Remove skill symlink if it points to us
  local skill_dst="$HOME/.claude/skills/ccs-orchestrator"
  if [ -L "$skill_dst" ]; then
    local target
    target=$(readlink "$skill_dst")
    if [[ "$target" == *"ccs-dashboard"* ]]; then
      rm "$skill_dst"
      ok "Removed skill symlink: ${skill_dst}"
    fi
  fi

  # Remove data directory
  local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard"
  if [ -d "$data_dir" ]; then
    if [ -f "$data_dir/overrides.jsonl" ]; then
      warn "Manual feature tags found: ${data_dir}/overrides.jsonl"
      read -rp "Delete data directory? [y/N] " confirm
      if [[ "$confirm" =~ ^[yY]$ ]]; then
        rm -rf "$data_dir"
        ok "Removed ${data_dir}"
      else
        warn "Kept ${data_dir}"
      fi
    else
      rm -rf "$data_dir"
      ok "Removed ${data_dir}"
    fi
  fi

  echo "Run 'source ~/.bashrc' or open a new terminal to take effect."
}

# ── Main ──
case "${1:-}" in
  --uninstall)
    do_uninstall
    ;;
  --check)
    echo "Checking dependencies..."
    check_deps
    echo
    if is_installed; then
      ok "Installed in ${BASHRC}"
    else
      warn "Not installed in ${BASHRC}"
    fi
    ;;
  --help|-h)
    echo "Usage: $0 [--uninstall|--check|--help]"
    echo
    echo "  (no args)     Install ccs-dashboard"
    echo "  --uninstall   Remove from ~/.bashrc"
    echo "  --check       Check dependencies and status"
    ;;
  *)
    do_install
    ;;
esac
