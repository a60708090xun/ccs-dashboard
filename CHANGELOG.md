# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [Semantic Versioning](https://semver.org/).

## [0.3.1] — 2026-04-16

### Added

- **Handled Gemini CLI v0.35+ JSON Object format** — Complete support for the new object-based session structure.
- **Robust Duck-typing parser** — Unified logic for extracting topics, turns, and tools across multiple Gemini and Claude versions.
- **Manual Archiving for Gemini** — Support for injecting `"archived": true` metadata via `ccs-crash --clean` to eliminate false positives.
- **Enhanced Process Detection** — Support for Happy Coder (Node.js) and standalone `gemini` processes.
- **Full Command Parity** — `ccs-recap`, `ccs-review`, `ccs-handoff`, `ccs-project`, and `ccs-overview` now fully support Gemini sessions.

### Fixed

- **Sequential Indexing** — Corrected turn indexing for Gemini sessions (1, 2, 3...) to match the interactive viewer and resume prompt.
- **ISO Millisecond Parsing** — Fixed `jq` date conversion for Gemini timestamps containing milliseconds.
- **SID Extraction Consistency** — Unified Gemini Session ID display (first 8 chars of UUID) across all modules.
- **Robustness** — Eliminated `jq` errors caused by `null` content fields in various downstream commands.

## [0.3.0] — 2026-04-10

### Added

- **Multi-Provider Dashboard** — Python session collection layer for Claude and Gemini CLI sessions (GH#40, PR #41)
- **ccs_collect.py** — unified Python-based session parser
- **ADR-003** — Code CLI Sessions definition

### Changed

- **ccs-status** — display PROV column and Gemini sessions
- **ccs-active** — support Gemini session display
- **ccs-sessions** — support Gemini session display
- **basename handling** — unified `.jsonl`/`.json` across all modules (9 files, 20 occurrences)

### Fixed

- **_ccs_collect_sessions regression** — restore backward-compatible TAB output format (GH#42, PR #43)
- **_out_projects** — restore encoded dir name for `_ccs_resolve_project_path`
- **ccs-overview / ccs-crash / ccs-feature** — fix field index for new prov column

## [0.2.1] — 2026-03-25

### Added

- **docs/sync-checklist.md** — cross-file consistency checklist for Phase 3

### Fixed

- **Topic tag leak** — strip XML tags (`<command-message>` etc.) from topic extraction (GH#28)
- **Crash expiry** — crashed sessions older than 3 days demoted to stale in ccs-status and ccs-overview (GH#28)
- **Health crash filter** — exclude crashed sessions from health report (GH#28)
- **Recap short session noise** — skip sessions with < 2 user prompts (GH#28)
- **Recap memory** — use streaming jq instead of `jq -s` for prompt count (GH#28)
- **Overview crash banner** — apply 3-day expiry consistent with ccs-status
- **Handoff unknown flags** — reject unknown `--` flags instead of treating as project dir
- **Crash stale hint** — show hint when crashes are older than 3 days

### Changed

- README: fix Chinese text in English version, sync zh-TW with missing commands
- install.sh: add ccs-crash and ccs-health to command list
- CLAUDE.md: Phase 3 cross-file check references sync-checklist
- Orchestrator SKILL.md: clarify verbatim output rule

## [0.2.0] — 2026-03-24

### Added

- **ccs-dispatch** — sync/async task dispatch with job tracking
- **ccs-health** — session health detection (context degradation, repeated reads)
- **_ccs_find_project_dir** — fuzzy match helper for path-to-project-dir encoding
- **_ccs_to_file** — tool output helper for skill integration
- Crash detection integrated into ccs-status and ccs-overview
- Checkpoint: grouped display with timestamps, done collapse

### Changed

- **Modular architecture** — split single `ccs-dashboard.sh` into 8 source modules (see ADR-001)
- Checkpoint: two-stage blocked classification, filter `Task:` sessions

### Fixed

- Path encoding mismatch for paths with underscores or hidden directories (GH#25)
- Checkpoint/recap: use friendly project name (GH#12)
- Orchestrator skill description for better triggering

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
