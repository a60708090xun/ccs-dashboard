# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/), versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **ccs-dispatch-run / ccs-dispatch-plan advisory AC lint** — before a hop's worker spawns (and for every hop `ccs-dispatch-plan` generates), each `verify.cmd` is scanned for a `"$(…)" = '<literal>'` comparison whose literal has two or more tokens. `AC_SORT_ORDER` re-sorts the literal with the real `sort` in the gate's locale when the substitution is a single pipeline ending in a plain `sort` followed only by order-preserving stages, and fires when the order changes, warning `this comparison can never be true` under the premise that every line is one token with no leading blank, quote or backslash — the case a C-collation literal under an `en_US` gate produces. Only the simplest shape is judged this way: the comparison's statement opens the command with `test`, `[` or `[[` (optionally negated), both operands are whole words, the substitution is a single line, and the command has no heredoc, no `LC_ALL`/`LC_COLLATE`/`LANG` name and no prefix assignment on any pipeline stage — the collation is always the gate's own, since an AC that sets its own locale or changes the environment in front cannot be judged reliably. Every other such comparison is flagged `AC_LITERAL_SET` as a suspected hand-computed literal; one inside a quoted string (a grep pattern, `bash -c '…'`) is not treated as a comparison. Hits go to stderr and, for runs, to `hop-NN-<id>/ac-lint.json` so false positives can be measured; verdicts, exit codes and the task.yaml schema are unchanged, and no warning does not mean the literal is right. (#128)
- **ccs-dispatch-run opencode executor; `ccs-dispatch --cli opencode|grok`** — `executor: opencode` runs the worker headless as `opencode run --auto [-m <model>] -- <prompt>` with stdin on `/dev/null` (opencode otherwise reads a non-TTY stdin into its message); `model:` is passed with `-m` only when declared, `backend: agentpager` is accepted, and `repro.json` records `opencode --version`. Its output is classified for `auth` only, from a provider-side string that another provider may not match (then the old RETRY path applies). ccs does not read agent-pager's opencode settings: opencode's auth must be reachable from the caller's environment, and exporting `XDG_DATA_HOME` for it also moves ccs-dashboard's own dispatch data directory, so `docs/commands.md` suggests a PATH wrapper instead. The job-spawn `--cli` (agentpager backend) now accepts `grok` and `opencode` besides `claude` and `gemini`. (#124)
- **ccs-dispatch-run classifies logged-out and unknown-model workers** — a headless claude or gemini worker that exits non-zero (not 124, and not 125/126/127, which keep their own classes) with a known auth or model-not-found message in the last 50 lines of its output now writes `worker-error` (`auth` / `model-not-found`), so the gate escalates instead of spending a retry on a failure judged deterministic. The string table goes stale on a CLI upgrade and then falls back to the old RETRY path; a model reply that quotes a table string can be misclassified, which escalates rather than accepts (#122)
- **ccs-dispatch-run separate worker and AC timeouts** — `execution_policy.worker_timeout_sec` and `ac_timeout_sec` bound the worker and each `verify.cmd` independently, each falling back to `timeout_sec` and then `CCS_DISPATCH_TIMEOUT`. The loader accepts only null or a positive integer for the new fields (#122)
- **ccs-dispatch-run per-attempt `repro.json`** — each attempt records the executor, declared model, first line of the CLI's `--version` (under `backend: agentpager` this is the orchestrator-side CLI) and the HEAD of `scope.cwd` at attempt start (#122)
- **ccs-run-cost** — cross-session run token accounting for orchestrator/worker rounds. Parses each session's `message.usage` and reports output / input / billable (`input + output`) / cache-read / cache-creation / thinking per session, with subagent transcripts attributed under their parent (parent subtotal, per-subagent rows, and a combined total all visible). Supports `--split` for stage breakdowns (a request at the cut lands in the later stage), `--until` for a cutoff (inclusive of that instant), `--label`, `--no-subagents`, and `md`/`json` output. Correctness hinges on one non-obvious rule: a single API request is split across several JSONL rows (one per content block, tagged `apiBlockIndex`) and every row carries a full `usage`, so rows are grouped by `requestId` and the highest-`apiBlockIndex` row wins — summing rows over-counts, and taking the first row under-counts badly because subagent transcripts carry mid-stream snapshots. Providers without `usage` (e.g. Gemini CLI) are marked unavailable rather than silently counted as zero, and are excluded from the grand total. Does not go through the unified collector, and leaves its subagents exclusion untouched. See `docs/commands.md`. (#117)
- **ccs-dispatch-run model passthrough** — a task's optional `model:` now actually selects the worker's model instead of only decorating the provenance trailer: headless passes `-m` (gemini) / `--model` (claude), and `backend: agentpager` writes a `model:` field into the launch file, where agent-pager's registry resolves the alias to the id its CLI accepts. Omitting the field keeps each CLI's own saved default. (#96)
- **ccs-dispatch-run** — deterministic review-gate dispatch with synchronous gated task-list chaining. Freezes a `task.yaml`, dispatches a worker, and re-runs each acceptance criterion's `verify.cmd` against the worktree (never trusting the worker's self-report); on FAIL it re-dispatches once with a machine-fact failure summary, then escalates. On a gate-PASS verdict it follows the task's optional `next:` field to the next task, verifying each hop; evidence lands under `runs/<chain-id>/hop-NN-<id>/` with a chain-level `chain.json`. Guards: cycle, depth (`CCS_DISPATCH_CHAIN_MAX_DEPTH`), and missing/invalid next-file. Returns exit 0/10/11 (accepted/escalated/hard_stop). The async `--chain` fast-path is unchanged. Tier ladder and Stage-2 automation are deferred. See `docs/commands.md`.
- `ccs-failure-triage`: triage a session for model confabulation-family failure signals (Sub-pattern A/B/C/D). Includes 5 automated forensic checks and writes a report to `<project>/tmp/`. See `docs/failure-triage.md`.
- **ccs-dispatch agent-pager backend** — optional local-channel worker backend (`CCS_DISPATCH_BACKEND=agentpager`, auto-detected) that runs a monitorable interactive worker via agent-pager instead of headless `claude -p`. Same-uid hybrid detection needs no `claude-broker` group; projects map to agent-pager keys via `~/.config/ccs-dashboard/proj-map`. Handoff-driven completion (`handoff-ready` status), async-only, and falls back to headless when agent-pager is unavailable. See `docs/commands.md`.
- **ccs-jobs agent-pager visibility** — the list shows a running agent-pager worker's last-activity in a footer line, and the single-job view hints the `.handoff` path plus a prefilled follow-up `ccs-dispatch` template on handoff-ready jobs. (PR #72)
- **ccs-dispatch completion notification** — an agentpager job pushes one short pager message at finalize (job id, status, project, `.handoff` path) via agent-pager's notify channel. Best-effort (a missing or hung sender never affects finalize), opt-out with `CCS_DISPATCH_NOTIFY=0`, bot slot pinned via `CCS_DISPATCH_NOTIFY_SLOT`. (#74)
- **ccs-dispatch preview sign-off** — `--preview` shows the worker prompt, project, backend, and seat, then asks for confirmation before dispatching; rejection, EOF, or timeout aborts with no job record. `--yes` skips the question for automation. (#75)
- **ccs-dispatch-run executor provenance trailer** — at completion, prints an advisory, copy-ready `X-Executor: <executor>/<model> (ccs-dispatch-run)` commit trailer so whoever commits the dispatched work can attribute the executor without hand-authoring it. The executor comes from the task (`claude` when omitted); the model from a new optional top-level `model:` field, gracefully degrading to an executor-only trailer when absent. Printed for every terminal outcome (accepted/escalated/hard_stop — the convention also covers escalate-then-orchestrator-commits), one line per distinct `executor[/model]` across chain hops. Advisory only: dispatch-run never commits and nothing is enforced. `chain.json` hops now also carry `executor`/`model`. See `references/task-yaml.md`.
- **ccs-dispatch chained handoffs** — `--chain [--max-depth N]` (agentpager only) auto-launches the next worker when one reports `outcome: done` + a non-empty `next:` in its handoff, within the same project, without routing the intermediate decision back through the lead session. Approved once up front; stops on `partial`/`blocked`/`failed`/empty-next/max-depth with a chain-termination pager notify. Lineage (`chain_parent`/`chain_depth`) shows in `ccs-jobs <id>`. An autonomy invariant (do not ask clarifying questions; blocked → `outcome: blocked`) now applies to all agentpager workers. See `docs/commands.md`.

### Fixed

- **ccs-dispatch-run no longer reports a chain as accepted when its next hop never ran** — after a PASS hop, a `next:` file that failed to load (missing, unparsable, invalid, or using a removed executor or field) or that pointed back into the chain stopped the chain while keeping the previous hop's `accepted` and exit 0, and the loader's message was discarded; with a single hop the output did not even name a stop reason. Both stops now end the chain `escalated` with exit 10 without spending `loop_budget`, `chain.json` gains `stop_detail` (the loader's message, or the repeated path for a cycle) and `ccs-dispatch-run` prints it on stderr, and the single-hop line appends `stop=<reason>` whenever the reason is not `empty-next`. Each hop's `final.json` keeps the gate's verdict; the `depth` cap still exits 0. (#125)
- **the chained-handoff contract no longer misdirects the worker or hides its own truncation** — four seams found while unifying the external handoff contract. The dispatch prompt recommended `ccs-handoff` "for the content", but that tool emits no frontmatter and writes elsewhere, so a worker following it would produce a file with no `outcome:` — which the continuation predicate reads as `failed`, reporting a completed hop as a failure with nothing pointing at the cause; the prompt now scopes `ccs-handoff` to the prose, keeps the frontmatter and path mandatory, and dictates `handoff_schema: handoff/v1` so both tracks describe the same shape. The chain context bridge truncated the parent handoff at `CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS` silently, and a structured handoff carries its ruled-out paths early enough that the 4000-byte default cuts them — the next hop then retries a dead end it was meant to inherit; a truncated bridge now ends with a marker naming the cap, the real size, and the parent handoff path (no default changed, and a non-numeric cap falls back to it rather than dropping the body whole). Documentation states that a handoff's `next:` is prose while a `task.yaml`'s `next:` is a path — the same key name, two types, and writing a path in the handoff raises no error, it just hands the next worker a contextless line. (#112)
- **ccs-dispatch-run no longer spends a retry on infrastructure** — the gate loop used to drop the worker's exit code on the headless path, so a crashed worker, a missing CLI and a worker that ran and did nothing were indistinguishable, and a failure that had nothing to do with the task still burned `loop_budget`. Every headless executor now records `attempt-NN/executor-exit-code` as evidence, and the deterministic subset of failures (exit 125/126/127, plus `backend: agentpager`'s daemon-down and no-proj-map) also writes `attempt-NN/worker-error`, which the gate turns into the ERROR verdict its pure judgement function already accepted — escalating on attempt 1 instead of retrying, and outranking a passing AC set. A timeout (124), a plain non-zero rc, an occupied agentpager seat and a failed launch write deliberately stay on the FAIL path, since those can still self-heal on the next attempt. `final.json` gains `worker_rc` and an `escalation.reason` of `gate` | `worker_error`, so the terminal state is readable without opening the worker trace. (#106)
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
