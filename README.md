# Code CLI Sessions (CCS) Dashboard

[中文版 (zh-TW)](docs/README.zh-TW.md)

Mission control for your Code CLI Sessions (Claude, Gemini, etc.) — track, review, and hand off across repos.

Code CLI tools store conversations as session files but give you little built-in tooling to review or manage them. ccs-dashboard parses those files so you can see what's happening across every session — by asking the agent in natural language, or straight from the command line.

## Background

If you use Code CLI Sessions heavily — multiple providers, multiple repos, multiple tasks in flight — you'll quickly hit these walls:

- **Sessions are invisible.** No built-in way to list, search, or compare sessions. Each terminal is its own silo. Close the tab and the context is gone.
- **Multi-repo chaos.** Working on a backend fix, a frontend feature, and a docs update simultaneously? Good luck remembering which session was doing what, in which repo.
- **Zombie processes pile up.** Suspended `claude` processes (from terminal multiplexers, crashed tabs, or `Ctrl+Z`) silently eat 190-500 MB each. No warning, no cleanup.
- **Context doesn't transfer.** Starting a new session means re-explaining everything. The old session's knowledge — files touched, decisions made, remaining todos — is trapped in a JSON/JSONL file nobody reads.
- **No cross-session view.** A single feature might span 5 sessions across 3 days. There's no way to see the full picture without manually digging through logs.

## Quick start

```bash
git clone https://github.com/a60708090xun/ccs-dashboard.git ~/tools/ccs-dashboard
cd ~/tools/ccs-dashboard
./install.sh              # Check deps, add source line to ~/.bashrc, create skill symlink
```

`./install.sh --check` reports status; `./install.sh --uninstall` removes it.

Or wire it up manually:

```bash
# Add to .bashrc:
source ~/tools/ccs-dashboard/ccs-dashboard.sh

# Skill symlink (optional):
ln -s ~/tools/ccs-dashboard/skills/ccs-orchestrator ~/.claude/skills/ccs-orchestrator
```

Then just ask Claude:

```
You: What am I working on?

Claude: (runs /ccs-orchestrator)

### ⚡ Active Sessions (4)

📁 backend-api (2)
🟢 1. Fix auth middleware regression    a1c4f8e2  3m ago
🔵 2. Add rate limiting endpoint        7b2e9d15  5h ago

### 📋 Pending Todos (3)
☐ Add rate limit headers to response    (backend-api)
☐ Write integration tests               (backend-api)
```

The bundled [skill](https://docs.anthropic.com/en/docs/claude-code/skills) gives you an interactive orchestrator with context-aware follow-up options — no commands to memorize. See [docs/commands.md](docs/commands.md) for a full walkthrough.

## Usage

ccs-dashboard has two layers:

**1. Claude Code skill** (`/ccs-orchestrator`) — the primary interface. Ask in natural language ("work status", "what am I working on") and get an interactive orchestrator with context-aware options. Read-only: it observes and presents, it does not control other sessions.

**2. CLI commands** — shell functions you can call directly from the terminal, for scripting, piping, or quick one-off lookups.

| Command | What it does |
|---------|-------------|
| `ccs` / `ccs-status` | Unified dashboard: active sessions + zombies + stale sessions |
| `ccs-cleanup` | Find and kill suspended zombie processes |
| `ccs-archive` | Manually mark a session as finished (archived) |
| `ccs-crash` | Detect crash-interrupted sessions + `--clean`/`--clean-all` cleanup |
| `ccs-resume-prompt` | Generate bootstrap prompt (< 2000 tokens) for a new session |
| `ccs-feature` | Track progress by feature/issue across sessions |
| `ccs-recap` | Daily work review across all projects |
| `ccs-details` | Interactive conversation browser (tig-like TUI) |
| `ccs-overview` | Cross-session overview: sessions + todos + git status |
| `ccs-checkpoint` | Lightweight progress snapshot: Done / In Progress / Blocked |
| `ccs-handoff` | Generate handoff notes with conversation summary, git, file ops |
| `ccs-health` | Session health detection — surface attention-degradation signals |
| `ccs-dispatch` | Dispatch a task to a new Claude Code session (async or sync) |
| `ccs-jobs` | View dispatch job history and results |
| `ccs-dispatch-plan` | Expand a chain-spec into a next:-linked task.yaml chain (no dispatch) |
| `ccs-dispatch-run` | Dispatch with a review gate + gated task-list chaining (task.yaml) |
| `ccs-review` | Session review report — stats, conversation, LLM summary (md/html/pdf) |
| `ccs-project` | Per-project insight report — cost, features, rhythm, code changes (md/html) |
| `ccs-failure-triage` | Triage a session for model confabulation-family failure signals |

All commands support both **Terminal ANSI** and **Markdown** (`--md`) output. See [docs/commands.md](docs/commands.md) for detailed flags, examples, the typical workflow, and status indicators.

## Requirements

**Platform:** Linux (remote server via SSH, local Linux, or WSL). Native Windows and macOS are not supported.

| Required | Purpose |
|----------|---------|
| bash 4+ | mapfile, associative arrays |
| jq | JSON/JSONL parsing |
| coreutils | stat, date, find |

| Optional | Purpose |
|----------|---------|
| less | ccs-details interactive viewer |
| xclip / xsel | ccs-resume-prompt --copy |

Data source: session logs under `~/.claude/projects/` (Claude) and `~/.gemini/` (Gemini).

## Documentation

- [docs/commands.md](docs/commands.md) — full CLI reference: flags, examples, typical workflow, status indicators
- [docs/architecture.md](docs/architecture.md) — module and file layout
- [docs/adr/](docs/adr/) — architecture decision records

## License

[MIT](LICENSE)
