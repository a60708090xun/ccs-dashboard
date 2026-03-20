# Daily Recap 功能設計

## 概述

為 ccs-dashboard 新增 daily recap 功能，讓使用者每天早上快速了解昨天的工作進度。
採用**雙層架構**：bash 層負責數據收集與格式化，skill 層負責 AI 上下文分析與建議。

## 需求摘要

| 項目 | 決策 |
|---|---|
| 觸發方式 | Bash 指令 `ccs-recap` + Skill 層 AI 分析 |
| 時間範圍 | 可自訂，預設自動偵測上次工作日 |
| 內容維度 | 7 項：sessions、todos、features、git、files、deadlines、今日建議 |
| 輸出格式 | terminal（預設）、`--md`、`--json` |
| 專案範圍 | 半自動：偵測有活動的專案，問使用者要掃哪些 |
| AI 分析深度 | 預設上下文分析，可升級到完整規劃 |

---

## Bash 層：`ccs-recap`

### 指令介面

```bash
ccs-recap [OPTIONS] [TIME_RANGE]

# 時間範圍
ccs-recap              # 預設：自動偵測上次工作日
ccs-recap 2d           # 最近 2 天
ccs-recap 2026-03-18   # 指定日期起算到現在

# 輸出格式
ccs-recap --md         # Markdown
ccs-recap --json       # JSON（供 skill 層消費）
ccs-recap -h / --help  # 使用說明

# 專案範圍（預設掃描所有有活動的專案）
ccs-recap --project    # 僅當前 pwd 專案
```

> **注意：** 不提供 `--all` flag——掃描所有專案是預設行為，無需顯式指定。
> 這與 `ccs-overview` 預設當前專案不同，因為 recap 的使用情境本質上是跨專案的。

### 上次工作日偵測邏輯

`_ccs_detect_last_workday` helper：

1. 掃描 `~/.claude/projects/` 下所有 JSONL 的 mtime
2. 從今天往回找，跳過今天，找到最近一個有 session 活動的日期
3. 以該日 00:00 為起點到現在為止

> **注意：** mtime 可能被非 session 操作更新（如索引工具讀取檔案）。
> 這是可接受的 trade-off——讀取每個 JSONL 內部時間戳太慢。
> 若偵測結果不準，使用者可用明確時間範圍覆蓋。

### 輸出區塊（7 個維度）

```
╔══════════════════════════════════════════╗
║  📋 Daily Recap — 2026-03-18 (Tue)      ║
║  Covering: 2026-03-18 00:00 ~ now       ║
╚══════════════════════════════════════════╝

── Sessions (3 active, 1 completed) ──────
  🟢 ccs-dashboard  Phase 3 feature tracking    2h ago
  🟡 firmware-tool  Fix UART timeout            5h ago
  ✅ ml-pipeline    Add data validation         18h ago (completed)
  💤 ccs-dashboard  Daily recap brainstorm      idle

── Todos ─────────────────────────────────
  ✅ Completed: 8    🔲 Pending: 3    🔄 In Progress: 1

  Pending:
  • [ccs-dashboard] Write design doc for daily recap
  • [firmware-tool] Add retry logic for UART
  • [ml-pipeline] Update test fixtures

── Features ──────────────────────────────
  🚀 GL#42 Phase 3 feature tracking  [8/10 todos done]
  🔧 GH#15 UART timeout fix          [2/5 todos done]
  ✅ GL#38 Data validation            [completed]

── Git Activity ──────────────────────────
  ccs-dashboard (master)  3 commits, 0 uncommitted
  firmware-tool (fix/uart) 1 commit, 2 uncommitted, 1 unpushed

── File Changes (top 5 hot files) ────────
  ccs-dashboard.sh  E:12 R:5  (ccs-dashboard)
  uart_handler.c    E:8  W:2  (firmware-tool)
  test_validate.py  E:6  R:3  (ml-pipeline)

── ⚠ Deadlines & Pending ────────────────
  [firmware-tool] "週五前要修好 UART" — 2 todos pending
  [ccs-dashboard] 3 pending todos, no deadline
```

### 新增 Helper Functions

| Function | 用途 |
|---|---|
| `_ccs_detect_last_workday` | 掃描 JSONL mtime，找上次有活動的日期 |
| `_ccs_recap_scan_projects` | 列出時間範圍內有活動的專案 |
| `_ccs_recap_collect` | 整合 7 個維度，輸出結構化數據 |
| `ccs-recap` | 主指令，dispatch 到各輸出格式 |

復用現有 helper（部分需擴充）：

- `_ccs_collect_sessions` — 現有版本硬編碼 7 天且跳過 archived sessions。
  **不直接修改此函數**（避免破壞 `ccs-overview`/`ccs-feature`），
  改由 `_ccs_recap_collect` 呼叫後再做時間窗口 post-filtering，
  並額外掃描 archived sessions（recap 需要顯示已完成的 session）。
- `_ccs_overview_session_data` — 取 todo、last exchange
- `_ccs_feature_cluster` / `_ccs_feature_md` — feature 狀態
- `_ccs_recent_files_md` — 現有版本僅輸出最近 15 筆 unique 檔案，不做頻率統計。
  `_ccs_recap_collect` 需新增 **per-file 操作次數聚合邏輯**（掃描 JSONL 中
  `tool_use` records，按檔案分組計算 Read/Edit/Write 次數），而非復用此 helper。

---

## Skill 層：ccs-orchestrator 擴充

### 觸發方式

在 ccs-orchestrator SKILL.md 新增：

**Command Palette 新增行：**

```
| recap | rc | `ccs-recap --json` + AI analysis — daily work recap |
```

**Routing Rules 新增：**

```
recap / daily recap / 昨天做了什麼 / 早安 / morning → recap 流程
```

### 執行流程

1. 執行 `ccs-recap --json` 取得結構化數據
2. 半自動專案篩選：
   - 列出有活動的專案
   - 問使用者要看哪些（預設全選）
3. 上下文分析：
   - 讀取每個 pending/in_progress session 的最後 2-3 對話
   - 用 `_ccs_get_pair` 取得（不需讀整個 JSONL）
   - 分析卡住原因、進展狀態
4. 輸出結構化 recap：
   - 數據摘要（來自 `ccs-recap --json`）
   - 各 session/feature 進度分析
   - 優先順序建議（根據 deadline + 卡住程度）
5. 問使用者是否要升級到完整規劃：
   - 是 → 生成今日工作計畫草稿（時間分配、順序建議）
   - 否 → 結束

### Skill 輸出範例

```markdown
## Daily Recap — 2026-03-18

### 進度總覽
昨天跨 3 個專案共 4 個 session，完成 8 個 todo，還有 3 個 pending。

### 各項工作分析

**🚀 GL#42 Phase 3 feature tracking** (ccs-dashboard)
進展順利，8/10 todos 完成。剩餘：design doc 撰寫和 spec review。
昨天最後在討論 daily recap 功能設計。

**🔧 GH#15 UART timeout fix** (firmware-tool)
卡在 retry logic 設計 — 上次對話討論到 exponential backoff
vs fixed interval，尚未決定。建議今天先做決策再繼續。

**✅ GL#38 Data validation** (ml-pipeline)
已完成，所有 todos done。可能需要 code review。

### 建議優先順序
1. **firmware-tool UART fix** — 有「週五前」deadline，且卡住需決策
2. **ccs-dashboard design doc** — 接近完成，收尾即可
3. **ml-pipeline code review** — 已完成，低優先
```

### 完整規劃模式（opt-in）

使用者選擇升級時，額外生成：

```markdown
### 今日工作計畫

| 優先 | 任務 | 專案 | 建議時段 | 說明 |
|---|---|---|---|---|
| 1 | 決定 retry 策略 | firmware-tool | 早上 | 需要清醒頭腦做設計決策 |
| 2 | 實作 retry logic | firmware-tool | 上午 | 決策完立即實作 |
| 3 | 收尾 design doc | ccs-dashboard | 下午 | 輕鬆收尾 |
| 4 | 發 code review | ml-pipeline | 空檔 | 非阻塞，隨時可做 |
```

### Token 成本控制

- 只讀取 pending session 的最後 2-3 pairs，不讀完整 JSONL
- `ccs-recap --json` 做前處理，避免 AI 層重複解析原始數據
- 完整規劃是 opt-in，不自動觸發

---

## 資料流架構

```
┌─────────────────────────────────────────────────┐
│  ~/.claude/projects/*/  (JSONL session files)    │
│  各專案 git repo                                 │
│  ~/.local/share/ccs-dashboard/features.jsonl     │
└──────────────┬──────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────┐
│  ccs-recap (bash 層)                             │
│                                                  │
│  1. _ccs_detect_last_workday → 時間起點          │
│  2. _ccs_collect_sessions + 時間窗口過濾          │
│  3. _ccs_recap_scan_projects → 有活動的專案列表   │
│  4. 對每個專案收集 7 個維度數據                    │
│  5. 輸出 terminal / --md / --json                │
└──────┬───────────────────┬──────────────────────┘
       │                   │
       ▼                   ▼
   terminal 直接看    ccs-orchestrator skill 層
                           │
                           ▼
                ┌─────────────────────────┐
                │  AI 分析流程             │
                │  1. parse JSON 數據      │
                │  2. 半自動專案篩選       │
                │  3. 讀 pending sessions  │
                │     最後 2-3 pairs       │
                │  4. 生成分析 + 建議      │
                │  5. 問是否升級完整規劃    │
                └─────────────────────────┘
```

## JSON 輸出結構（bash → skill 契約）

```json
{
  "recap_period": {
    "from": "2026-03-18T00:00:00",
    "to": "2026-03-19T09:30:00",
    "auto_detected": true
  },
  "projects": [
    {
      "name": "ccs-dashboard",
      "path": "/pool2/chenhsun/tools/ccs-dashboard",
      "sessions": [
        {
          "id": "abc-123",
          "topic": "Phase 3 feature tracking",
          "status": "idle",
          "last_active": "2026-03-18T17:30:00",
          "todos": { "done": 8, "pending": 2, "in_progress": 0 },
          "pending_items": ["Write design doc", "Spec review"],
          "last_exchange_preview": "user: OK 繼續..."
        }
      ],
      "features": [
        {
          "id": "GL#42",
          "label": "Phase 3 feature tracking",
          "status": "in_progress",
          "todos": { "done": 8, "total": 10 }
        }
      ],
      "git": {
        "branch": "master",
        "commits_in_period": 3,
        "uncommitted": 0,
        "unpushed": 0
      },
      "hot_files": [
        { "file": "ccs-dashboard.sh", "edits": 12, "reads": 5 }
      ],
      "deadlines": [
        { "text": "週五前要修好 UART", "session_id": "abc-123", "session_topic": "Fix UART timeout" }
      ]
    }
  ],
  "summary": {
    "total_sessions": 4,
    "active": 3,
    "completed": 1,
    "todos_done": 8,
    "todos_pending": 3,
    "todos_in_progress": 1
  }
}
```

## 實作細節補充

### Deadline 資料萃取

現有 `_ccs_overview_session_data` 用關鍵字 grep 掃描 user messages，回傳 pipe-separated
flat string。`_ccs_recap_collect` 需將此轉換為結構化 JSON：

1. 對每個 session 呼叫 `_ccs_overview_session_data`，取得 `deadline_context` 欄位
2. 若非空，解析為 `{ text, session_id, session_topic }` 結構
3. 這是 best-effort keyword matching，非精確日期解析——AI skill 層負責解讀語意

### Git commits 時間範圍過濾

`commits_in_period` 使用 `git log --after="<recap_period.from>" --oneline` 計算：

```bash
git -C "$project_path" log --after="$from_ts" --oneline 2>/dev/null | wc -l
```

此方式依賴 git 內建的時間過濾，精確且低成本。

### Hot files 聚合邏輯

與 `_ccs_recent_files_md`（僅列最近 15 筆 unique 檔案）不同，recap 需要 per-file
操作頻率統計。實作方式：

1. 掃描時間範圍內 session JSONL 的 `tool_use` records（type: Read/Edit/Write）
2. 以檔案路徑為 key，聚合各操作類型的次數
3. 按總操作次數排序，取 top 5

### Skill 層 YOLO mode 處理

在 YOLO mode 下 `AskUserQuestion` 回傳空值。Skill 層的「半自動專案篩選」應：
- 偵測到 YOLO mode 時，預設選擇所有有活動的專案，不提問
- 使用一般文字 + `<options>` 區塊替代 `AskUserQuestion`

---

## 範圍邊界（What this is NOT）

- `ccs-recap` **不修改** 任何 session 狀態或 JSONL 檔案
- `ccs-recap` **不寫入** features.jsonl（僅讀取）
- `ccs-recap` **不觸發** 任何 git 操作（僅讀取 status/log）
- Skill 層 **不自動執行** 完整規劃，必須使用者 opt-in

---

## install.sh 更新

`ccs-recap` 作為 `ccs-dashboard.sh` 的新函數，隨現有安裝流程自動可用，不需額外安裝步驟。

僅需更新 README 文件記錄新指令。

## 測試計畫

1. **`_ccs_detect_last_workday`** — 驗證跨週末偵測（週一 → 週五）
2. **時間範圍過濾** — 驗證 `2d`、指定日期、預設模式
3. **多專案掃描** — 驗證預設（全部專案）vs `--project` 篩選
4. **三種輸出格式** — terminal、`--md`、`--json` 各自正確
5. **JSON 結構** — 驗證 skill 層可正確 parse
6. **空資料邊界** — 無 session 活動時的 graceful 處理
7. **Skill 整合** — orchestrator 觸發 recap 流程 end-to-end
