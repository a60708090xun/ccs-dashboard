# Code CLI Sessions (CCS) Dashboard

[English](../README.md)

Code CLI Sessions (Claude, Gemini 等) 的任務指揮中心 — 跨 repo 追蹤、回顧、交接。

Code CLI 工具將對話存放在特定目錄中，但缺乏統一的管理介面。ccs-dashboard 解析這些對話紀錄，讓你直接問 agent 或從 terminal 掌握所有 session 狀態。

## 背景

如果你重度使用 Code CLI Sessions — 多個 Provider、多個 repo、多個任務同時進行 — 很快會撞上這些牆：

- **Session 是隱形的。** Claude Code 沒有內建方式列出、搜尋或比較 session。每個 terminal 都是獨立的孤島，關掉 tab 就失去 context。
- **多 repo 混亂。** 同時修後端 bug、做前端功能、更新文件？你很難記得哪個 session 在哪個 repo 做什麼。
- **殭屍 process 堆積。** 被 suspend 的 `claude` process（來自 terminal multiplexer、tab crash、`Ctrl+Z`）默默吃掉每個 190-500 MB RAM，沒有警告、沒有清理機制。
- **Context 無法傳遞。** 開新 session 就要重新解釋一切。舊 session 的知識 — 碰了哪些檔案、做了什麼決定、還剩什麼待做 — 困在沒人看的 JSONL 裡。
- **沒有跨 session 視角。** 一個 feature 可能橫跨 5 個 session、3 天時間，沒有辦法一次看到完整面貌 — commit、待辦、時間軸 — 只能手動翻 log。

## 快速開始

```bash
git clone https://github.com/a60708090xun/ccs-dashboard.git ~/tools/ccs-dashboard
cd ~/tools/ccs-dashboard
./install.sh              # 檢查依賴、加 source 行到 ~/.bashrc、建立 skill 連結
```

`./install.sh --check` 檢查狀態；`./install.sh --uninstall` 移除。

或手動設定：

```bash
# 在 .bashrc 加入：
source ~/tools/ccs-dashboard/ccs-dashboard.sh

# Skill 連結（選用）——冪等，且會修復不見或斷掉的連結：
./skills/install.sh
```

接著直接問 Claude：

```
You: 我現在在做什麼？

Claude: (runs /ccs-orchestrator)

### ⚡ Active Sessions (4)

📁 backend-api (2)
🟢 1. Fix auth middleware regression    a1c4f8e2  3m ago
🔵 2. Add rate limiting endpoint        7b2e9d15  5h ago

### 📋 Pending Todos (3)
☐ Add rate limit headers to response    (backend-api)
☐ Write integration tests               (backend-api)
```

內建的 [skill](https://docs.anthropic.com/en/docs/claude-code/skills) 會啟動互動式指揮台和 context-aware follow-up options，不用記指令。完整操作流程見 [commands.md](commands.md)。共兩支，見下方「使用方式」。

## 使用方式

ccs-dashboard 分兩層：

**1. Claude Code Skills** — `/ccs-orchestrator` 是主要介面。用自然語言問（「工作狀態」「我在做什麼」），得到互動式指揮台和 context-aware options。唯讀：只讀取和呈現資訊，不控制其他 session。另一支是 `/ccs-dispatch-run`，把一次 dispatch 帶過它的 review gate；同名的 CLI 指令也存在，兩種身分共用一個名字。

**2. CLI 指令** — 可以從 terminal 直接呼叫的 shell function，適合腳本、pipe、快速查詢。

| 指令 | 功能 |
|------|------|
| `ccs` / `ccs-status` | 統一 dashboard：活躍 session + 殭屍 process + 過期 session |
| `ccs-cleanup` | 找出並清理被 suspend 的殭屍 process |
| `ccs-archive` | 手動標記 session 為已完成（存檔） |
| `ccs-crash` | 偵測 crash 中斷的 session + `--clean`/`--clean-all` 清理 |
| `ccs-resume-prompt` | 產生精簡 bootstrap prompt（< 2000 tokens），貼入新 session 即可接手 |
| `ccs-feature` | 以 feature/issue 為單位的跨 session 進度追蹤 |
| `ccs-recap` | 每日工作回顧 — 跨專案彙整 session/todo/git 活動 |
| `ccs-details` | 互動式對話瀏覽器（類似 tig 的 TUI） |
| `ccs-overview` | 跨 session 工作總覽：session + 待辦 + git 狀態 |
| `ccs-checkpoint` | 輕量進度快照：Done / In Progress / Blocked |
| `ccs-handoff` | 產生交接筆記：對話摘要、git 狀態、檔案操作 |
| `ccs-health` | Session 健康偵測 — 偵測注意力退化信號 |
| `ccs-dispatch` | 派發任務到新的 Claude Code session（async 或 sync） |
| `ccs-jobs` | 查看 dispatch 任務歷史與結果 |
| `ccs-dispatch-plan` | 把 chain-spec 展開成 next:-linked task.yaml 鏈（只產檔、不派工） |
| `ccs-dispatch-run` | 帶 review gate + 鏈結派工（gated task-list chaining，task.yaml） |
| `ccs-review` | Session 回顧報告 — 統計、對話、LLM 摘要（md/html/pdf） |
| `ccs-project` | 專案層級洞察報告 — 成本、進度、節奏、程式碼變動（md/html） |
| `ccs-failure-triage` | 對 session 進行 model confabulation-family 失效信號分類診斷 |

所有指令支援 **Terminal ANSI** 和 **Markdown**（`--md`）兩種輸出模式。詳細參數、範例、典型工作流程與狀態圖示見 [commands.md](commands.md)。

## 依賴

**適用環境：** Linux 環境（透過 SSH 連線的遠端 server、本地 Linux、或 WSL）。不支援原生 Windows 和 macOS。

| 必要 | 用途 |
|------|------|
| bash 4+ | mapfile, associative arrays |
| jq | JSON/JSONL 解析 |
| coreutils | stat, date, find |

| 選用 | 用途 |
|------|------|
| less | ccs-details 互動模式展開 |
| xclip / xsel | ccs-resume-prompt --copy |

資料來源：`~/.claude/projects/` (Claude) 與 `~/.gemini/` (Gemini) 下的 session log。

## 文件

- [commands.md](commands.md) — 完整 CLI 參考：參數、範例、典型工作流程、狀態圖示
- [architecture.md](architecture.md) — 模組與檔案結構
- [adr/](adr/) — 架構決策紀錄

## 授權

[MIT](../LICENSE)
