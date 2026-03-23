# ccs-dashboard

[中文版 (zh-TW)](docs/README.zh-TW.md)

Mission control for your Claude Code sessions — track, review, and hand off across repos.

Claude Code stores conversations as JSONL files under `~/.claude/projects/`, but provides no built-in tools to review or manage them. ccs-dashboard parses these JSONL files so you can see what's going on across all your sessions — either by asking Claude directly or from the command line.

## Background

If you use Claude Code heavily — multiple repos, multiple terminals, multiple tasks in flight — you'll quickly hit these walls:

- **Sessions are invisible.** No built-in way to list, search, or compare sessions. Each terminal is its own silo. Close the tab and the context is gone.
- **Multi-repo chaos.** Working on a backend fix, a frontend feature, and a docs update simultaneously? Good luck remembering which session was doing what, in which repo.
- **Zombie processes pile up.** Suspended claude processes (from terminal multiplexers, crashed tabs, or `Ctrl+Z`) silently eat 190-500 MB each. No warning, no cleanup.
- **Context doesn't transfer.** Starting a new session means re-explaining everything. The old session's knowledge — files touched, decisions made, remaining todos — is trapped in a JSONL file nobody reads.
- **No cross-session view.** A single feature might span 5 sessions across 3 days. There's no way to see the full picture without manually digging through logs.

## Before / After

**Before:** You're left staring at raw JSONL files.

```
$ ls ~/.claude/projects/
-home-alice-backend-api/    -home-alice-frontend/    -home-alice-docs/
$ ls ~/.claude/projects/-home-alice-backend-api/
3a8f1c42-...jsonl  7b2e9d15-...jsonl  a1c4f8e2-...jsonl
# Now what? Open each 50MB JSONL in vim?
```

**After:** Just ask Claude. The included [custom skill](https://docs.anthropic.com/en/docs/claude-code/skills) gives you an interactive orchestrator — no commands to memorize.

```
You: What am I working on?

Claude: (runs /ccs-orchestrator)

### ⚡ Active Sessions (4)

📁 backend-api (2)
🟢 1. Fix auth middleware regression    a1c4f8e2  3m ago
🔵 2. Add rate limiting endpoint       7b2e9d15  5h ago

📁 frontend (1)
🟡 3. Dashboard redesign v2            9f3b7a21  45m ago

### 📋 Pending Todos (3)
☐ Add rate limit headers to response          (backend-api)
☐ Write integration tests                     (backend-api)
☐ Update sidebar component                    (frontend)

### 🧟 Zombie Processes (2)
PID 28341  Tl  490 MB  2d ago
PID 31022  Tl  312 MB  1d ago

<options>
- d 1 — Expand session #1 recent conversations
- f gh65 — View rate limiting feature progress
- rc — Daily work recap
- cl — Clean up zombie processes
</options>
```

The skill handles routing, context, and follow-up options automatically. You can also drill down:

```
You: Show me what's left on the rate limiting feature

Claude: (runs ccs-feature gh65)

### 🟡 GH#65 Add rate limiting [backend-api]
    Todos: 2/5 | Sessions: 3 | Last: 45m ago

    Recent commits:
    a3f1c82  feat: add token bucket rate limiter
    9b2e7d1  feat: add Redis-backed rate limit store

    Remaining todos:
    ☐ Add rate limit headers to response
    ☐ Write integration tests
    ☐ Update API docs
```

Every feature is also available as a shell command for scripting or quick lookups:

```
$ ccs-status --md                     # Session dashboard
$ ccs-resume-prompt --stdout          # Bootstrap prompt for new session
$ ccs-feature gh65                    # Cross-session feature tracking
$ ccs-recap                           # Daily work review
```

## How it works

ccs-dashboard has two layers:

**1. Claude Code Skill** (`/ccs-orchestrator`) — the primary interface. Ask in natural language, get an interactive orchestrator with context-aware options. No commands to remember.

- Trigger: `/ccs-orchestrator`, or natural language like "work status", "what am I working on"
- Read-only — observes and presents information, does not control other sessions
- Features: Command Palette, natural language routing, context-aware follow-up options

**2. CLI commands** — shell functions you can call directly from terminal. Useful for scripting, piping, or quick one-off lookups.

| Command | What it does |
|---------|-------------|
| `ccs` / `ccs-status` | Unified dashboard: active sessions + zombies + stale sessions |
| `ccs-cleanup` | Find and kill suspended zombie processes |
| `ccs-crash` | Detect crash-interrupted sessions + `--clean`/`--clean-all` cleanup |
| `ccs-resume-prompt` | Generate bootstrap prompt (< 2000 tokens) for new session |
| `ccs-feature` | Track progress by feature/issue across sessions |
| `ccs-recap` | Daily work review across all projects |
| `ccs-details` | Interactive conversation browser (tig-like TUI) |
| `ccs-overview` | Cross-session overview: sessions + todos + git status |
| `ccs-checkpoint` | Lightweight progress snapshot: Done / In Progress / Blocked |
| `ccs-handoff` | Generate handoff notes with conversation summary, git, file ops |
| `ccs-health` | Session health detection — 偵測注意力退化信號 |
| `ccs-dispatch` | Dispatch a task to a new Claude Code session (async or sync) |
| `ccs-jobs` | View dispatch job history and results |

All commands support both **Terminal ANSI** and **Markdown** (`--md`) output modes.

### ccs-health

Session health detection — 偵測注意力退化信號。

```bash
# 全域掃描所有 active sessions
ccs-health
# Markdown 輸出
ccs-health --md
# JSON 輸出
ccs-health --json
# 指定 session
ccs-health <session-id-prefix>
```

三個偵測指標：
- 重複 tool call（同一檔案被 Read/Grep 多次）
- Session 持續時間
- Prompt-response 輪數

分級顯示：🟢 green / 🟡 yellow / 🔴 red

閾值可透過環境變數覆蓋（見 `ccs-health.sh`）。

See **[docs/commands.md](docs/commands.md)** for detailed usage, flags, and examples.

## Install

```bash
git clone https://github.com/a60708090xun/ccs-dashboard.git ~/tools/ccs-dashboard
cd ~/tools/ccs-dashboard
./install.sh            # Check deps + add source line to ~/.bashrc + create skill symlink
./install.sh --check    # Check dependencies and installation status
./install.sh --uninstall  # Remove
```

Or manually:

```bash
# Add to .bashrc:
source ~/tools/ccs-dashboard/ccs-dashboard.sh

# Skill symlink (optional):
ln -s ~/tools/ccs-dashboard/skills/ccs-orchestrator ~/.claude/skills/ccs-orchestrator
```

## Status indicators

```
Terminal          Markdown    State       Meaning
Green             🟢          active      < 10 min since last activity
Yellow            🟡          recent      < 1 hour
Blue              🔵          idle        < 1 day (open but idle)
Gray              💤          stale       > 1 day (zombie candidate)
Red 💀            💀          crashed     crash-interrupted (reboot/hung/dead process)
Strikethrough     -           archived    has last-prompt marker
```

## Requirements

**Platform:** Linux environment (remote server via SSH, local Linux, or WSL). Native Windows and macOS are not supported.

| Required | Purpose |
|----------|---------|
| bash 4+ | mapfile, associative arrays |
| jq | JSONL parsing |
| coreutils | stat, date, find |

| Optional | Purpose |
|----------|---------|
| less | ccs-details interactive viewer |
| xclip / xsel | ccs-resume-prompt --copy |

Data source: JSONL session logs under `~/.claude/projects/`.

## File structure

```
ccs-core.sh                      # Helpers + basic commands (sessions/active/cleanup)
ccs-dashboard.sh                 # Sources ccs-core.sh + advanced commands
install.sh                       # Installer (deps check + bashrc + skill symlink)
skills/ccs-orchestrator/SKILL.md # Claude Code skill — primary interface
docs/commands.md                 # Detailed CLI command reference
```

## License

[MIT](LICENSE)
