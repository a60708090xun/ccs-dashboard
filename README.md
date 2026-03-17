# ccs-dashboard

Claude Code Session 管理的輕量 TUI 工具。個人工具，非官方。

Terminal 模式用 ANSI escape codes 渲染，Markdown 模式可在 Happy Coder 網頁版直接顯示。

## 安裝

```bash
# 在 .bashrc 加入：
source ~/tools/ccs-dashboard/ccs-dashboard.sh
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
| `ccs-handoff [project-dir]` | 產生 session 交接筆記 |

## 顏色 / 狀態圖示

```
Terminal          Markdown
綠色              🟢          active    < 10 分鐘
黃色              🟡          recent    < 1 小時
藍色              🔵          idle      < 1 天（開著但閒置）
灰色              💤          stale     > 1 天（殭屍候選）
灰色刪除線         -          archived  有 last-prompt 標記
```

## 指令說明

### ccs-status (ccs)

一眼掌握所有 session 狀態，分三個區塊：
1. **Active Sessions** — 近 1 天內有活動的未封存 session
2. **Zombie Processes** — 被 suspend 的 claude process（吃 RAM）
3. **Stale Sessions** — 超過 1 天未動的未封存 session

```bash
ccs-status          # Terminal ANSI 輸出
ccs-status --md     # Markdown list 格式（預設，手機友善）
ccs-status --md --table   # Markdown table 格式（桌面寬螢幕）
```

Markdown 模式會產生帶編號的 session 列表，搭配 `ccs-pick` 互動瀏覽。

### ccs-pick N

展開 `ccs-status --md` 列表中第 N 個 session 的最近對話。

```bash
ccs-pick --md 3           # 顯示最後 3 組 prompt-response（預設）
ccs-pick --md -n 5 3      # 顯示最後 5 組
ccs-pick --md --full 3:9  # 完整展開第 3 個 session 的第 9 個 prompt response
```

使用流程：
1. `ccs-status --md` → 看到帶編號的 session 列表
2. `ccs-pick --md 3` → 展開 #3 的最近 3 組對話（response 截 10 行）
3. `ccs-pick --md --full 3:9` → 完整展開被截斷的 response

### ccs-sessions [hours]

列出指定時間內的所有 session（含已封存），按專案分組。

### ccs-active [days]

只列出未封存（open）的 session，適合快速找到還在進行中的工作。

### ccs-cleanup

找出 Stopped 狀態（`Tl`/`T`）的 claude process 並終止。
這些通常是 waveterm `/exit` 後被 SIGTSTP suspend 的殭屍，每個佔 190-500 MB RAM。

```bash
ccs-cleanup           # 互動確認後清理
ccs-cleanup --dry-run # 只列出，不殺
ccs-cleanup --force   # 跳過確認直接清理
```

### ccs-details [session-id-prefix]

互動式對話瀏覽器（Terminal），列出 session 中所有 user prompt，可上下選擇並展開完整回應。

```bash
ccs-details 4e716490      # 用 session ID 前綴指定
ccs-details               # 目前專案目錄的最近 session
ccs-details -a            # 搜尋所有專案
ccs-details --last        # 非互動：只顯示最後一組 prompt + response
```

互動模式按鍵：

```
↑/↓, j/k   導航
Enter       展開完整 prompt + response（用 less 翻頁）
g/G         跳到最舊/最新
q, Esc      退出
```

### ccs-html

產生 standalone HTML dashboard 檔案（GitHub dark theme 風格）。

```bash
ccs-html              # 產生 dashboard.html
ccs-html --open       # 產生後用瀏覽器開啟
```

### ccs-handoff [project-dir]

為指定專案產生交接筆記（Markdown），包含：
- Open session 列表
- 最近 session 的對話脈絡
- Git 狀態（branch、recent commits、uncommitted changes）
- 待填寫的骨架：目前進度 / 下一步 / 重要決策

輸出位置：`~/docs/tmp/handoff/<date>-<topic>.md`

## Topic 來源

Session topic 的取得優先順序：
1. Happy Coder title（`mcp__happy__change_title` 最後一次設定的值）
2. 第一則 user message

## 依賴

- bash, jq, coreutils (stat, date, find)
- less（ccs-details 互動模式展開用）
- 讀取 `~/.claude/projects/` 下的 JSONL session log
