# ccs-dashboard

[English](../README.md)

Claude Code session 的任務指揮中心 — 跨 repo 追蹤、回顧、交接。

Claude Code 把對話存在 `~/.claude/projects/` 的 JSONL 檔裡，但沒有內建工具讓你回顧或管理這些 session。ccs-dashboard 解析這些 JSONL，讓你直接問 Claude 或從 terminal 掌握所有 session 狀態。

## 背景

如果你重度使用 Claude Code — 多個 repo、多個 terminal、多個任務同時進行 — 很快會撞上這些牆：

- **Session 是隱形的。** Claude Code 沒有內建方式列出、搜尋或比較 session。每個 terminal 都是獨立的孤島，關掉 tab 就失去 context。
- **多 repo 混亂。** 同時修後端 bug、做前端功能、更新文件？你很難記得哪個 session 在哪個 repo 做什麼。
- **殭屍 process 堆積。** 被 suspend 的 claude process（來自 terminal multiplexer、tab crash、`Ctrl+Z`）默默吃掉每個 190-500 MB RAM，沒有警告、沒有清理機制。
- **Context 無法傳遞。** 開新 session 就要重新解釋一切。舊 session 的知識 — 碰了哪些檔案、做了什麼決定、還剩什麼待做 — 困在沒人看的 JSONL 裡。
- **沒有跨 session 視角。** 一個 feature 可能橫跨 5 個 session、3 天時間，沒有辦法一次看到完整面貌 — commit、待辦、時間軸 — 只能手動翻 log。

## 使用前 vs 使用後

**使用前：** 只能翻 JSONL 原始檔。

```
$ ls ~/.claude/projects/
-home-alice-backend-api/    -home-alice-frontend/    -home-alice-docs/
$ ls ~/.claude/projects/-home-alice-backend-api/
3a8f1c42-...jsonl  7b2e9d15-...jsonl  a1c4f8e2-...jsonl
# 然後呢？用 vim 開 50MB 的 JSONL？
```

**使用後：** 直接問 Claude，內建的 [custom skill](https://docs.anthropic.com/en/docs/claude-code/skills) 會啟動互動式指揮台 — 不用記指令。

```
You: 我現在在做什麼？

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
- d 1 — 展開 session #1 最近對話
- f gh65 — 查看 rate limiting feature 進度
- rc — 今日工作回顧
- cl — 清理殭屍 process
</options>
```

Skill 會自動處理路由、context、follow-up options。也可以進一步追問：

```
You: rate limiting feature 還剩什麼？

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

每個功能也可以直接用 shell 指令：

```
$ ccs-status --md                     # Session dashboard
$ ccs-resume-prompt --stdout          # 產生接手 prompt
$ ccs-feature gh65                    # 跨 session feature 追蹤
$ ccs-recap                           # 每日工作回顧
```

## 運作方式

ccs-dashboard 分兩層：

**1. Claude Code Skill** (`/ccs-orchestrator`) — 主要介面。用自然語言問，得到互動式指揮台和 context-aware options，不用記指令。

- 觸發方式：`/ccs-orchestrator`，或自然語言如「工作狀態」「我在做什麼」
- 唯讀 — 只讀取和呈現資訊，不控制其他 session
- 功能：Command Palette、自然語言路由、context-aware follow-up options

**2. CLI 指令** — 可以從 terminal 直接呼叫的 shell function，適合腳本、pipe、快速查詢。

| 指令 | 功能 |
|------|------|
| `ccs` / `ccs-status` | 統一 dashboard：活躍 session + 殭屍 process + 過期 session |
| `ccs-cleanup` | 找出並清理被 suspend 的殭屍 process |
| `ccs-resume-prompt` | 產生精簡 bootstrap prompt（< 2000 tokens），貼入新 session 即可接手 |
| `ccs-feature` | 以 feature/issue 為單位的跨 session 進度追蹤 |
| `ccs-recap` | 每日工作回顧 — 跨專案彙整 session/todo/git 活動 |
| `ccs-details` | 互動式對話瀏覽器（類似 tig 的 TUI） |
| `ccs-overview` | 跨 session 工作總覽：session + 待辦 + git 狀態 |
| `ccs-crash` | 偵測 crash 中斷的 session + `--clean`/`--clean-all` 清理 |
| `ccs-handoff` | 產生交接筆記：對話摘要、git 狀態、檔案操作 |
| `ccs-checkpoint` | 輕量進度快照：Done / In Progress / Blocked |
| `ccs-health` | Session 健康偵測 — 偵測注意力退化信號 |
| `ccs-dispatch` | 派發任務到新的 Claude Code session（async 或 sync） |
| `ccs-jobs` | 查看 dispatch 任務歷史與結果 |

所有指令支援 **Terminal ANSI** 和 **Markdown** (`--md`) 兩種輸出模式。

### ccs-health

Session 健康偵測 — 偵測注意力退化信號。

```bash
ccs-health                    # 掃描所有 active session
ccs-health --md               # Markdown 輸出
ccs-health --json             # JSON 輸出
ccs-health <session-prefix>   # 指定 session
```

三個偵測指標：
- 重複 tool call（同一檔案被 Read/Grep 多次）
- Session 持續時間
- Prompt-response 輪數

分級顯示：🟢 green / 🟡 yellow / 🔴 red

閾值可透過環境變數覆蓋（見 `ccs-health.sh`）。

詳細用法、參數、範例請見 **[commands.md](commands.md)**。

## 安裝

```bash
git clone https://github.com/a60708090xun/ccs-dashboard.git ~/tools/ccs-dashboard
cd ~/tools/ccs-dashboard
./install.sh            # 檢查依賴 + 加 source 行到 ~/.bashrc + 建立 skill symlink
./install.sh --check    # 只檢查依賴和安裝狀態
./install.sh --uninstall  # 移除
```

或手動：

```bash
# 在 .bashrc 加入：
source ~/tools/ccs-dashboard/ccs-dashboard.sh

# Skill symlink（選用）：
ln -s ~/tools/ccs-dashboard/skills/ccs-orchestrator ~/.claude/skills/ccs-orchestrator
```

## 狀態圖示

```
Terminal          Markdown    狀態        說明
綠色              🟢          active      < 10 分鐘
黃色              🟡          recent      < 1 小時
藍色              🔵          idle        < 1 天（開著但閒置）
灰色              💤          stale       > 1 天（殭屍候選）
紅色 💀           💀          crashed     crash 中斷（重開機/hung/dead process）
灰色刪除線         -          archived    有 last-prompt 標記
```

## 依賴

**適用環境：** Linux 環境（透過 SSH 連線的遠端 server、本地 Linux、或 WSL）。不支援原生 Windows 和 macOS。

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

## 檔案結構

```
ccs-core.sh       # 共用 helper + 基礎指令 (sessions/active/cleanup)
ccs-dashboard.sh   # 入口 — source 所有模組 + ccs-status, ccs-pick
ccs-viewer.sh      # ccs-html, ccs-details
ccs-handoff.sh     # ccs-handoff, ccs-resume-prompt
ccs-overview.sh    # ccs-overview + render helpers
ccs-feature.sh     # Feature clustering + ccs-feature, ccs-tag
ccs-ops.sh         # ccs-crash, ccs-recap, ccs-checkpoint
ccs-health.sh      # Session health 評分
ccs-dispatch.sh    # ccs-dispatch, ccs-jobs
install.sh         # 安裝腳本（依賴檢查 + bashrc + skill symlink）
skills/            # Claude Code skill — 主要介面
docs/              # CLI 指令參考 + 歸檔設計文件
```

## 授權

[MIT](../LICENSE)
