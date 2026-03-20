# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-03-20

First official release.

### Added

- **ccs-status (ccs)** — unified dashboard: active sessions + zombies + stale
- **ccs-sessions** — list all sessions within N hours
- **ccs-active** — list open (non-archived) sessions within N days
- **ccs-cleanup** — kill stopped/suspended claude processes
- **ccs-pick** — interactive session detail viewer
- **ccs-details** — tig-like TUI conversation browser
- **ccs-html** — HTML dashboard generator
- **ccs-overview** — cross-session work overview (sessions + todos + git)
- **ccs-feature** — feature/issue progress tracking across sessions
- **ccs-tag** — manual session-to-feature assignment
- **ccs-handoff** — generate session handoff notes
- **ccs-resume-prompt** — generate bootstrap prompt for new sessions
- **ccs-recap** — daily work recap across all projects
- **ccs-crash** — crash-interrupted session detection (PR #10)
- **ccs-checkpoint** — lightweight progress snapshot: Done / In Progress / Blocked (PR #11)
- **ccs-orchestrator** — Claude Code skill for interactive work orchestration
