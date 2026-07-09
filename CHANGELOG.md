# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **ccs-dispatch-run** — deterministic review-gate dispatch (scope C: gate + single retry). Freezes a `task.yaml`, dispatches a worker, and re-runs each acceptance criterion's `verify.cmd` against the worktree (never trusting the worker's self-report); on FAIL it re-dispatches once with a machine-fact failure summary, then escalates. Writes structured evidence under `dispatch/runs/<run-id>/` and returns exit 0/10/11 (accepted/escalated/hard_stop). Tier ladder, chain wiring, and Stage-2 automation are deferred. See `docs/commands.md`.
- `ccs-failure-triage`: triage a session for model confabulation-family failure signals (Sub-pattern A/B/C/D). Includes 5 automated forensic checks and writes a report to `<project>/tmp/`. See `docs/failure-triage.md`.
- **ccs-dispatch agent-pager backend** — optional local-channel worker backend (`CCS_DISPATCH_BACKEND=agentpager`, auto-detected) that runs a monitorable interactive worker via agent-pager instead of headless `claude -p`. Same-uid hybrid detection needs no `claude-broker` group; projects map to agent-pager keys via `~/.config/ccs-dashboard/proj-map`. Handoff-driven completion (`handoff-ready` status), async-only, and falls back to headless when agent-pager is unavailable. See `docs/commands.md`.
- **ccs-jobs agent-pager visibility** — the list shows a running agent-pager worker's last-activity in a footer line, and the single-job view hints the `.handoff` path plus a prefilled follow-up `ccs-dispatch` template on handoff-ready jobs. (PR #72)
- **ccs-dispatch completion notification** — an agentpager job pushes one short pager message at finalize (job id, status, project, `.handoff` path) via agent-pager's notify channel. Best-effort (a missing or hung sender never affects finalize), opt-out with `CCS_DISPATCH_NOTIFY=0`, bot slot pinned via `CCS_DISPATCH_NOTIFY_SLOT`. (#74)
- **ccs-dispatch preview sign-off** — `--preview` shows the worker prompt, project, backend, and seat, then asks for confirmation before dispatching; rejection, EOF, or timeout aborts with no job record. `--yes` skips the question for automation. (#75)
- **ccs-dispatch chained handoffs** — `--chain [--max-depth N]` (agentpager only) auto-launches the next worker when one reports `outcome: done` + a non-empty `next:` in its handoff, within the same project, without routing the intermediate decision back through the lead session. Approved once up front; stops on `partial`/`blocked`/`failed`/empty-next/max-depth with a chain-termination pager notify. Lineage (`chain_parent`/`chain_depth`) shows in `ccs-jobs <id>`. An autonomy invariant (do not ask clarifying questions; blocked → `outcome: blocked`) now applies to all agentpager workers. See `docs/commands.md`.

### Fixed

- `ccs-jobs` status sync is now agent-pager-aware: resolves effective status via the same reduce-merge as the board (fallback markers no longer skip liveness), uses the worker tmux session instead of the monitor pid as the liveness signal, and defers to a live monitor during worker startup to avoid falsely completing a just-dispatched job. (PR #72)

## [0.3.3] — 2026-04-17

### Added

- **ccs-archive <SID>** — New command to manually mark a session as finished. Supports both Claude (.jsonl) and Gemini (.json) formats.
- **Enhanced ccs-status threshold** — Increased active session visibility from 1 day to 7 days to match `ccs-active` behavior.
- **Complete Documentation** — Added usage guides for `ccs-archive` and synced thresholds across all manual pages.

## [0.3.2] — 2026-04-17

### Fixed

- **Gemini Crash Detection Accuracy** — Improved process detection to support node-wrapped instances (NVM) and resolved false positives via absolute project path matching. (GH#39, PR #48)
- **Crash Window Synchronization** — Unified the 7-day (10080 min) detection window across status, crash, and active commands.
- **Archive Consistency** — Ensured archived sessions are excluded from `ccs-sessions` and `ccs-active` by default.
- **Source Loading** — Fixed "Not a directory" errors in `ccs-dashboard.sh` when sourced from the current directory.
- **UI Clarity** — Added `(Claude)` / `(Gemini)` provider labels to the `ccs-crash --clean` interactive interface.

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
