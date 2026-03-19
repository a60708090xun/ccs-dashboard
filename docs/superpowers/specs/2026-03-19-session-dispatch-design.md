# ccs-dashboard Session Dispatch 設計

日期：2026-03-19
狀態：Draft
背景研究：`~/docs/ai-context/session-dispatch-research.md`

## 目標

讓 ccs-dashboard 能啟動 Claude Code session 執行任務，從 orchestrator 一鍵派工。使用者透過指揮層（orchestrator/shell）下達指令，不直接與 dispatched session 互動。

## MVP 範圍

| 包含 | 不包含（未來） |
|------|--------------|
| `ccs-dispatch` 指令 | Daemon |
| `ccs-jobs` 查詢 | 多輪追問 |
| 同步 / 非同步模式 | tmux 整合 |
| 可選 context 注入 | session `--resume` 續接 |
| JSONL + result 檔追蹤 | Web UI |
| Lazy + ccs-cleanup 清理 | API rate limiting |
| Orchestrator 路由 | 跨機器 dispatch |

## 設計決策

- **指揮官模式**：使用者在 orchestrator session 裡派工，不切到 dispatched session 互動
- **`claude -p` 非互動模式**：同步與非同步差別在是否 blocking wait
- **檔案系統追蹤**：不引入 daemon，用 JSONL index + result 檔 + PID file
- **背景派工階段再評估 daemon 需求**
- **MVP 不支援追問**：dispatched session 是 one-shot

---

## §1 指令介面

### ccs-dispatch

```bash
ccs-dispatch [--sync] [--context] [--timeout <secs>] --project <dir> "task description"
```

| 參數 | 預設 | 說明 |
|------|------|------|
| `--sync` | 否（非同步） | Blocking 等結果，stdout 印 .out 和 .err |
| `--context` | 否 | 注入目標專案的 git 狀態 + active session 待辦（需 git repo） |
| `--timeout <secs>` | 600 | 任務超時秒數，超時狀態為 `timeout` |
| `--project <dir>` | **必填** | 目標專案目錄，claude 會在該目錄執行 |
| `"task"` | **必填** | 任務描述，作為 `claude -p` 的 prompt |

### ccs-jobs

```bash
ccs-jobs [--all] [<job-id>]
```

- 無參數：列出最近 20 筆 jobs，顯示 job-id、狀態、age、專案、任務摘要前 60 字
- `--all`：列出所有 jobs
- 有 job-id：印出該 job 的完整結果（若 result 檔已過期則顯示 JSONL 中的 summary）

---

## §2 資料結構與檔案佈局

### 儲存位置

```
${XDG_DATA_HOME:-~/.local/share}/ccs-dashboard/dispatch/
├── jobs.jsonl              # Index（indefinitely retained，可手動清除）
├── results/
│   ├── <job-id>.out        # 完整 stdout（7 天 TTL）
│   └── <job-id>.err        # stderr（7 天 TTL）
└── pids/
    └── <job-id>.pid        # 非同步 job 的 PID file（完成後刪除）
```

### jobs.jsonl 格式

```json
{
  "job_id": "d-20260319-143052-a1b2",
  "project": "/pool2/chenhsun/tools/ccs-dashboard",
  "task": "fix lint warnings in ccs-core.sh",
  "context_injected": true,
  "mode": "async",
  "status": "running",
  "pid": 12345,
  "created_at": "2026-03-19T14:30:52+08:00",
  "finished_at": null,
  "exit_code": null,
  "summary": null
}
```

### Job ID 格式

`d-YYYYMMDD-HHMMSS-<4字隨機hex>` — 避免碰撞且可按時間排序。

### 狀態流轉

```
running → completed (exit 0)
        → failed (exit ≠ 0)
        → timeout (exit 124, by timeout command)
```

### JSONL 更新策略

採用 **append-latest-wins**：更新狀態時 append 新行（同 job_id），讀取時以最後一筆為準。避免多個背景 process 同時 read-modify-write 的 race condition。`ccs-jobs` 以 `job_id` 去重取最後出現的記錄。

---

## §3 執行流程

### 同步模式（`--sync`）

```
ccs-dispatch --sync --project /path "fix lint"
  │
  ├─ 產生 job-id
  ├─ [--context] → 組合 context prompt（git status + todos）
  ├─ 寫 jobs.jsonl（status: running）
  ├─ cd <project> && timeout <secs> claude -p "prompt" > results/<job-id>.out 2> results/<job-id>.err
  ├─ 等待完成（exit 124 = timeout）
  ├─ Append jobs.jsonl（status, exit_code, finished_at, summary）
  ├─ stdout 印出 .out 內容，若有 .err 也一併顯示
  └─ 刪除 PID file（若有）
```

### 非同步模式（預設）

```
ccs-dispatch --project /path "fix lint"
  │
  ├─ 產生 job-id
  ├─ [--context] → 組合 context prompt
  ├─ 寫 jobs.jsonl（status: running）
  ├─ 背景執行：
  │    (cd <project> && timeout <secs> claude -p "prompt" \
  │      > results/<job-id>.out 2> results/<job-id>.err; \
  │      _ccs_dispatch_finish <job-id> $?) &
  ├─ 寫 PID file
  └─ 印出 "Job dispatched: d-20260319-143052-a1b2"
```

### `_ccs_dispatch_finish` 回呼

- Append jobs.jsonl 新行（status、exit_code、finished_at、summary）
- Summary 提取：取 .out 最後 30 行，截斷至 200 字元（含不完整行則去尾）
- `rm -f` PID file（冪等，避免 fast-finish race）

### Context 組合（`--context`）

```
[Project: /pool2/chenhsun/tools/ccs-dashboard]
[Git branch: feat/dispatch, uncommitted: 3 files]
[Active todos from recent sessions:]
- [ ] implement dispatch command
- [x] add jobs.jsonl schema

---
Task: fix lint warnings in ccs-core.sh
```

用專用 helper `_ccs_dispatch_context` 提取指定專案的 git 狀態和 active session todos，格式化成 prompt prefix。不呼叫完整 `_ccs_overview_json`（避免掃描所有專案）。

---

## §4 清理機制

### Lazy cleanup

每次 `ccs-dispatch` 執行時順手跑一次：

```bash
_ccs_dispatch_lazy_cleanup() {
  # 刪除 7 天前的 results/*.out 和 *.err
  find "$dispatch_dir/results" -type f -mtime +7 -delete 2>/dev/null
  # 清除孤立 PID file（process 已不存在）
  for pidfile in "$dispatch_dir/pids"/*.pid; do
    kill -0 "$(cat "$pidfile")" 2>/dev/null || rm "$pidfile"
  done
}
```

### ccs-cleanup 整合

在現有 `ccs-cleanup` 加一段掃描 dispatch 目錄：
- 刪除過期 result 檔
- 清除孤立 PID file
- 可選 `--dispatch-all` 清除所有 dispatch 歷史

### ccs-jobs Lazy status sync

`ccs-jobs` 查詢時檢查所有 `running` 狀態 job 的 PID，若 process 已結束則更新 jobs.jsonl。

---

## §5 Orchestrator 整合

### 路由新增

| 指令 | 別名 | 執行方式 | 說明 |
|------|------|---------|------|
| `dispatch --project <dir> "task"` | `dp` | **直接執行**（強制非同步） | Bash tool 執行 `ccs-dispatch`，回傳 job-id |
| `jobs` | `j` | **直接執行** | 執行 `ccs-jobs`，顯示 dispatch 歷史 |
| `job <id>` | | **直接執行** | 執行 `ccs-jobs <id>`，顯示單筆結果 |

### 執行規則

- **讀取類指令**（`jobs`、`job`）：直接執行，安全
- **Spawn 類指令**（`dispatch`）：Orchestrator 內一律非同步，直接透過 Bash tool 執行 `ccs-dispatch`（不帶 `--sync`）
- `--sync` 僅供使用者在 shell 手動使用，Orchestrator 不提供此選項

### 自然語言路由

- 「派工」「dispatch」「跑一下」→ `dispatch`
- 「任務狀態」「dispatch 結果」→ `jobs`

---

## §6 安全考量

- **Task prompt 傳遞**：task 作為 `claude -p` 的引號參數傳入，不經過 `eval`
- **並行數警告**：`ccs-dispatch` 檢查目前 running jobs 數量，超過 3 個時警告（不硬擋）
- **專案目錄驗證**：`--project` 路徑必須存在；使用 `--context` 時需為 git repo
- **新 code 位置**：dispatch 相關函式放在 `ccs-dashboard.sh` 內，與現有指令一致
- **不自動 commit/push**：dispatch 的 task prompt 不會自動加入 commit/push 指令，除非使用者明確寫在 task 裡

---

## §7 可配置參數

所有可調整參數透過 shell 變數定義預設值，使用者可在 `.bashrc` 或環境變數中覆蓋。

```bash
# 任務超時秒數（--timeout 預設值）
CCS_DISPATCH_TIMEOUT=${CCS_DISPATCH_TIMEOUT:-600}

# ccs-jobs 預設列出筆數
CCS_DISPATCH_JOBS_LIMIT=${CCS_DISPATCH_JOBS_LIMIT:-20}

# ccs-jobs 任務摘要顯示字數
CCS_DISPATCH_TASK_DISPLAY_LEN=${CCS_DISPATCH_TASK_DISPLAY_LEN:-60}

# result 檔 TTL 天數
CCS_DISPATCH_RESULT_TTL_DAYS=${CCS_DISPATCH_RESULT_TTL_DAYS:-7}

# summary 提取：從 .out 末尾取幾行
CCS_DISPATCH_SUMMARY_LINES=${CCS_DISPATCH_SUMMARY_LINES:-30}

# summary 截斷字元數上限
CCS_DISPATCH_SUMMARY_MAX_CHARS=${CCS_DISPATCH_SUMMARY_MAX_CHARS:-200}

# 並行 running job 警告門檻
CCS_DISPATCH_MAX_CONCURRENT_WARN=${CCS_DISPATCH_MAX_CONCURRENT_WARN:-3}
```

實作中所有對應的 hard-coded 值一律引用這些變數，不直接寫死數字。
