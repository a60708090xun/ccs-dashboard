# ccs-dashboard

Claude Code Session 管理的輕量 TUI 工具。個人工具，非官方。

Terminal 模式用 ANSI escape codes 渲染，Markdown 模式可在 Happy Coder 網頁版直接顯示。

## 安裝

```bash
cd ~/tools/ccs-dashboard
./install.sh            # 檢查依賴 + 加 source 行到 ~/.bashrc + 建立 skill symlink
./install.sh --check    # 只檢查依賴和安裝狀態
./install.sh --uninstall  # 移除
```

或手動：

```bash
# 在 .bashrc 加入：
source ~/tools/ccs-dashboard/ccs-dashboard.sh

# Skill symlink：
ln -s ~/tools/ccs-dashboard/skills/ccs-orchestrator ~/.claude/skills/ccs-orchestrator
```

## 檔案結構

```
ccs-core.sh                      # helpers + 基礎指令 (sessions/active/cleanup)
ccs-dashboard.sh                 # source ccs-core.sh + 大型指令 (status/pick/html/details/handoff/resume-prompt/overview)
install.sh                       # 安裝腳本（含 skill symlink）
skills/ccs-orchestrator/SKILL.md # Claude Code skill — 互動式工作指揮台
docs/commands.md                 # 各指令詳細使用方式
```

## 指令一覽

| 指令 | 說明 |
|------|------|
| `ccs` / `ccs-status` | 統一 dashboard：活躍 session + 殭屍 process + 過期 session |
| `ccs-status --md` | Markdown 輸出（Happy 網頁版友善） |
| `ccs-sessions [hours]` | 列出指定時間內所有 session（預設 24 小時，含 archived） |
| `ccs-active [days]` | 列出未封存 session（預設 7 天） |
| `ccs-cleanup [--dry-run\|--force]` | 清理 Stopped 狀態的殭屍 process |
| `ccs-details [session-id]` | 互動式對話瀏覽器，類似 tig |
| `ccs-pick N` | 展開第 N 個 session 的最近對話（搭配 `--md` 用） |
| `ccs-html` | 產生 HTML dashboard 檔案 |
| `ccs-handoff [project-dir]` | 產生 session 交接筆記（自動填充對話摘要、git、檔案操作、TodoWrite） |
| `ccs-resume-prompt [session-id]` | 產生精簡 bootstrap prompt（< 2000 tokens），貼入新 session 即可接手 |
| `ccs-overview` | 跨 session 工作總覽：活躍 session + 待辦 + git 狀態 + deadline context |
| `ccs-feature` | 以 feature/issue 為單位的跨 session 進度追蹤 |
| `ccs-tag` | 手動標記 session 歸屬到指定 feature |
| `ccs-recap` | 每日工作回顧 — 跨專案 session/todo/feature/git 摘要 |

各指令的詳細用法、參數、範例請見 **[docs/commands.md](docs/commands.md)**。

## Skills

| Skill | 說明 |
|-------|------|
| `ccs-orchestrator` | 互動式工作指揮台（Claude Code Skill） |

### ccs-orchestrator

跨 session 工作指揮台。觀察所有 active Claude Code session 的狀態、待辦事項、git 狀態，並提供互動式導覽。

- **定位：** 觀察者 + 顧問 — 只讀取和呈現資訊，不控制其他 session
- **觸發方式：** 在 Claude Code 中輸入 `/ccs-orchestrator`，或自然語言如「工作狀態」「我在做什麼」
- **功能：** Command Palette、自然語言路由、context-aware options

`install.sh` 會自動建立 symlink 到 `~/.claude/skills/ccs-orchestrator`。

## 顏色 / 狀態圖示

```
Terminal          Markdown
綠色              🟢          active    < 10 分鐘
黃色              🟡          recent    < 1 小時
藍色              🔵          idle      < 1 天（開著但閒置）
灰色              💤          stale     > 1 天（殭屍候選）
灰色刪除線         -          archived  有 last-prompt 標記
```

## Topic 來源

Session topic 的取得優先順序：
1. Happy Coder title（`mcp__happy__change_title` 最後一次設定的值）
2. 第一則 user message

## 依賴

| 必要 | 用途 |
|------|------|
| bash 4+ | mapfile, associative arrays |
| jq | JSONL 解析 |
| coreutils | stat, date, find |

| 選用 | 用途 |
|------|------|
| less | ccs-details 互動模式展開 |
| xclip / xsel | ccs-resume-prompt --copy |

資料來源：`~/.claude/projects/` 下的 JSONL session log。
