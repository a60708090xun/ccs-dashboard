# ccs-checkpoint — 輕量級工作進度快照

## 概述

新增 `ccs-checkpoint` 命令，提供彈性時間切片的三欄式進度摘要（Done / In Progress / Blocked），用於早上 recap 或會議前彙報。

與 `ccs-recap`（日報等級）互補，`ccs-checkpoint` 專注做更短區間的 checkpoint。

## CLI 介面

```bash
ccs-checkpoint                    # 上次 checkpoint 到現在（首次用今天 00:00）
ccs-checkpoint --since 9:00       # 今天 09:00 起
ccs-checkpoint --since yesterday  # 昨天 00:00 起
ccs-checkpoint --since "2h ago"   # 2 小時前起
ccs-checkpoint --md               # markdown 條列式輸出
ccs-checkpoint --md --table       # markdown 表格式輸出（無 todos 展開）
ccs-checkpoint --project          # 只看當前目錄的專案
```

`--table` 僅在搭配 `--md` 時有效，單獨使用會被忽略。

## 時間區間邏輯

### `--since` 預設

1. 讀取 `${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard/last-checkpoint` 的時間戳
2. 找不到 → fallback 今天 00:00
3. 每次以預設區間執行後，**在資料收集完成後**更新 `last-checkpoint` 為當前時間（last-writer-wins；多 terminal 同時執行時後者覆蓋前者，可接受）
4. 明確指定 `--since` 時**不更新**記錄

### `--since` 格式支援

需自訂 parser `_ccs_checkpoint_parse_since`，因為部分格式不相容 GNU `date -d`：

| 格式 | 範例 | 解析方式 | `date -d` 相容 |
|------|------|---------|:---:|
| HH:MM | `9:00` | 前綴 `today ` 後餵 `date -d` | 需前處理 |
| `yesterday` | `yesterday` | 直接 `date -d "yesterday 00:00"` | Yes |
| `Nh ago` | `2h ago` | 自訂：展開為 `"N hours ago"` | 需前處理 |
| `Nm ago` | `30m ago` | 自訂：展開為 `"N minutes ago"` | 需前處理 |
| ISO date | `2026-03-20` | 直接 `date -d` | Yes |
| ISO datetime | `2026-03-20T09:00` | 直接 `date -d` | Yes |

## 三欄分類邏輯

每個 session 恰好歸入一欄，優先順序：Done > Blocked > In Progress。

### Done

區間內 archived 的 session（JSONL 尾端有 `"type":"last-prompt"` marker 且 mtime >= since_epoch）。

顯示內容：專案名 + session topic。

> **已知限制：** Done 以 mtime 判斷，與 `ccs-recap` 一致。如果 session 在區間之前就已 archived 且之後沒被寫入，不會出現在 Done 欄。這是刻意選擇——checkpoint 反映「這段時間內有動靜的東西」。

### In Progress

區間內有活動（mtime >= since_epoch）、未 archived、且**不符合 Blocked 條件**的 session。

顯示內容：專案名 + session topic + 展開的 todos（pending / in_progress items）。

### Blocked

從 In Progress 候選中，符合以下任一條件的 session **移入 Blocked**（不再顯示在 In Progress）：

- **inactive > 2 小時**（mtime 在區間內但距今 > 2 小時，表示啟動後長時間無更新）
- 最後 5 則非 meta user message 含 blocked / 卡住 / 等待 / waiting / stuck 等 keyword

> 注意：此處 "inactive > 2h" 與 `ccs-core.sh` 的 "stale"（> 1 day）是不同概念，刻意使用不同術語。

## 輸出格式

### Terminal（預設）

```
━━ Checkpoint (09:00 → 14:32) ━━

✅ Done
  ccs-dashboard  首次掃描工作目錄範圍討論

🔄 In Progress
  ccs-dashboard  ccs-checkpoint 功能發想
    - [~] 釐清需求
    - [ ] 提出方案

⚠️ Blocked
  (none)

── 2 sessions · 1 done · 1 in progress · 0 blocked ──
```

Footer counter 語意：
- **N sessions** = 區間內有活動的 session 總數（Done + In Progress + Blocked）
- **done / in progress / blocked** = 各欄的 session 數量，三者加總 = N sessions

### Markdown 條列式（`--md`）

```markdown
## Checkpoint (09:00 → 14:32)

### Done
- **ccs-dashboard** — 首次掃描工作目錄範圍討論

### In Progress
- **ccs-dashboard** — ccs-checkpoint 功能發想
  - [~] 釐清需求
  - [ ] 提出方案

### Blocked
- (none)
```

### Markdown 表格式（`--md --table`）

```markdown
## Checkpoint (09:00 → 14:32)

| 狀態 | 專案 | 項目 |
|------|------|------|
| Done | ccs-dashboard | 首次掃描工作目錄範圍討論 |
| WIP | ccs-dashboard | ccs-checkpoint 功能發想 (2 todos) |
```

表格模式不展開 todos，僅標註數量。

## 資料來源

- Session JSONL: `~/.claude/projects/**/*.jsonl`（排除 `subagents/`）
- 時間過濾: 以 JSONL 檔案 mtime 為準（與 `ccs-recap` 一致）
- `--project` 解析：用 `_ccs_resolve_jsonl ""` 取得當前目錄最近的 JSONL，再 `basename "$(dirname ...)"` 取得編碼後的專案目錄名（與 `ccs-recap --project` 相同路徑）

## 實作細節

### 檔案位置

- 主邏輯加在 `ccs-dashboard.sh`，放在 `ccs-recap` 區塊附近
- timestamp 檔案: `${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard/last-checkpoint`

### 複用現有 helpers

| Helper | 用途 |
|--------|------|
| `_ccs_recap_scan_projects` | 列出有活動的專案目錄（僅做第一層篩選） |
| `_ccs_topic_from_jsonl` | 取得 session topic |
| `_ccs_resolve_project_path` | 編碼目錄名 → 實際路徑 |
| `_ccs_resolve_jsonl` | `--project` 模式解析當前目錄 |

### Todos 擷取

不直接複用 `_ccs_todos_md`（它輸出所有 status 的 items）。改用 `_ccs_recap_collect` 的 inline jq pattern：

```bash
jq -s -r '[.[] | select(.type == "assistant") | .message.content[]? |
  select(.type == "tool_use" and .name == "TodoWrite") |
  .input.todos] | last // [] | .[]? | [.status, .content] | @tsv' "$jsonl"
```

再過濾只取 `pending` / `in_progress` items。

### Session 迭代

`_ccs_checkpoint_collect` 需要逐 session 迭代（不只逐 project），結構參考 `_ccs_recap_collect` 的內層 loop：

1. `_ccs_recap_scan_projects` 取得專案目錄列表
2. 每個專案目錄下 `find *.jsonl`
3. 每個 JSONL 檢查 mtime、archived status、todos、blocked keywords
4. 分類到 Done / Blocked / In Progress

### 新增函式

| 函式 | 職責 |
|------|------|
| `_ccs_checkpoint_parse_since` | 解析 `--since` 參數為 epoch（自訂 parser） |
| `_ccs_checkpoint_collect` | 逐 session 掃描，分類三欄，輸出 JSON |
| `_ccs_checkpoint_terminal` | Terminal ANSI 輸出 |
| `_ccs_checkpoint_md` | Markdown 條列式輸出 |
| `_ccs_checkpoint_table` | Markdown 表格式輸出 |
| `ccs-checkpoint` | 主入口，解析參數、呼叫上述函式 |

### install.sh 更新

在 `do_install` 的 commands 列表中加入 `ccs-checkpoint`。
