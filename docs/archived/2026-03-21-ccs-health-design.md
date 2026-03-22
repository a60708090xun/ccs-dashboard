# ccs-health — Session Health Detection 設計文件

> **日期：** 2026-03-21
> **Issue：** GH#17
> **狀態：** Draft

---

## 一、目標

新增 `ccs-health` 指令，主動偵測 LLM agent session 的注意力退化信號，以分級方式呈現健康狀態，協助使用者判斷何時該切換 session。

### 定位
- ccs-dashboard = 觀察層（session 發生了什麼）
- ccs-health = 行動層的第一步（session 健不健康）
- 半自動：偵測 + 報告 + 分級，不自動切換

### 通用化策略
- **介面通用化：** 輸出標準化 JSON report，不綁定特定 agent 平台
- **Parser 先做 Claude Code：** JSONL 萃取邏輯先只支援 Claude Code 格式，未來其他 agent 只需實作相同格式的 event stream 萃取

---

## 二、MVP 範圍

### 做的事
- 三個偵測指標（重複 tool call、session 持續時間、prompt-response 輪數）
- 分級顯示（green / yellow / red）
- 獨立 `ccs-health` 指令（全域掃描 + 指定 session）
- 整合進 `ccs-status` / `ccs-overview`（簡要 badge）
- 閾值 hardcode + 環境變數可覆蓋
- 輸出格式：terminal（ANSI）、markdown、JSON

### 不做的事
- Task velocity 下降偵測（noise 大，留後續）
- Context 使用率偵測（/cost 輸出不在 JSONL）
- Rule 遵從度分析（scope 太大）
- 全自動 session 切換
- 退化預測模型
- Health metrics 持久化（即時算，不存 log）
- Resume prompt 自動生成（使用者看到 red 自己決定）

---

## 三、架構

### 檔案結構

新增獨立檔案 `ccs-health.sh`，被 `ccs-dashboard.sh` source。

```
ccs-health.sh          ← 新增
ccs-core.sh            ← 既有，提供基礎設施
ccs-dashboard.sh       ← 既有，source ccs-health.sh
install.sh             ← 更新安裝清單
skills/ccs-orchestrator/SKILL.md  ← 更新選單
```

### 三層架構

```
資料層: _ccs_health_events()
  → 接收 JSONL 檔案路徑（$1），jq 萃取 event stream

計算層: _ccs_health_score()
  → 透過 stdin 接收 event stream JSON，輸出分級結果

展示層: ccs-health [session-id] [--md|--json]
  → 格式化輸出
```

### 依賴關係

```
ccs-health.sh
  ├─ source ccs-core.sh（JSONL 路徑、session 列舉）
  ├─ 使用 _ccs_topic_from_jsonl()（展示層取 topic）
  └─ 被 ccs-dashboard.sh source（整合用）
```

---

## 四、資料層 — Event Stream 萃取

### `_ccs_health_events()`

參數：`$1` = JSONL 檔案路徑（與 ccs-core.sh 慣例一致）

從 JSONL 萃取統一格式的 event stream，輸出到 stdout：

```json
{
  "session_id": "abc123",
  "first_ts": "2026-03-21T09:00:00",
  "last_ts": "2026-03-21T11:30:00",
  "prompt_count": 25,
  "tool_reads": {
    "/path/to/file.sh": 4,
    "/path/to/other.md": 2
  },
  "tool_greps": {
    "keyword": 3,
    "other_pattern": 1
  }
}
```

### 設計決策
- **session_id 來源：** 取自 JSONL 檔名前 8 字元（`basename "$f" .jsonl | cut -c1-8`），與 ccs-core.sh 慣例一致
- **jq 實作策略：** 使用 `jq --slurp` + `reduce` 一次萃取所有欄位。Session JSONL 通常數千行（< 10MB），`--slurp` 的記憶體開銷可接受。若未來遇到超大 session，可改為 streaming reduce 或多 pass
- **prompt_count 定義：** `type == "user"` 且 `(.message.content | type == "string")` 且 `(.isMeta | not)`，排除 tool_result、meta message、空字串。與 ccs-dashboard.sh 現有 prompt 計數邏輯一致
- `tool_reads` 和 `tool_greps` 分開追蹤（語義不同）
- **tool_greps key：** 直接用 `.input.pattern` 字串當 key。同一 pattern 搜不同目錄視為同一次（因為關注的是「agent 是否重複搜同一件事」而非搜索位置）
- 只計算 assistant 的 tool_use（user 的不算）
- `first_ts` / `last_ts` 從 JSONL 第一筆和最後一筆含 timestamp 的紀錄取
- 此 event stream 格式即為通用化接口——未來其他 agent 只需產出同樣格式

---

## 五、計算層 — Health Score

### `_ccs_health_score()`

透過 stdin 接收 event stream JSON（pipe 傳入），輸出分級結果到 stdout。

用法：`_ccs_health_events "$jsonl" | _ccs_health_score`

### 三個指標與分級

**1. 重複 tool call（dup_tool）**

`tool_reads` 中同一 file_path 被 Read 的最大次數，與 `tool_greps` 中同一 pattern 的最大次數，兩者取較大值。

```
green:  max_count < 3
yellow: max_count >= 3 且 < 5
red:    max_count >= 5
```

**2. Session 持續時間（duration）**

`last_ts - first_ts`，換算成分鐘。

```
green:  < 960 min (16hr)
yellow: >= 960 且 < 1440 min (24hr)
red:    >= 1440 min
```

**3. Prompt-response 輪數（rounds）**

`prompt_count` 值。

```
green:  < 30
yellow: >= 30 且 < 60
red:    >= 60
```

### 總分級

取三個指標中最嚴重的：
- 任一 red → session 整體 red
- 無 red 但有 yellow → 整體 yellow
- 全 green → 整體 green

### 環境變數（全部有預設值）

```
CCS_HEALTH_DUP_YELLOW=3
CCS_HEALTH_DUP_RED=5
CCS_HEALTH_DURATION_YELLOW=960
CCS_HEALTH_DURATION_RED=1440
CCS_HEALTH_ROUNDS_YELLOW=30
CCS_HEALTH_ROUNDS_RED=60
```

### 輸出格式（JSON）

```json
{
  "session_id": "abc123",
  "overall": "yellow",
  "indicators": {
    "dup_tool": {
      "level": "green",
      "value": 2,
      "threshold": {"yellow": 3, "red": 5}
    },
    "duration": {
      "level": "yellow",
      "value": 150,
      "unit": "min",
      "threshold": {"yellow": 120, "red": 240}
    },
    "rounds": {
      "level": "green",
      "value": 18,
      "threshold": {"yellow": 30, "red": 60}
    }
  }
}
```

---

## 六、展示層 — ccs-health 指令

### 用法

```bash
ccs-health                          # 全域掃描
ccs-health --md                     # Markdown 輸出
ccs-health --json                   # JSON 輸出
ccs-health <session-id-prefix>      # 指定 session
ccs-health <session-id-prefix> --json
```

### 展示層依賴

除了 `_ccs_health_events()` / `_ccs_health_score()` 外，展示層另需呼叫：
- `_ccs_topic_from_jsonl()` — 取得 session topic
- `_ccs_friendly_project_name()` — 取得專案名稱
- `_ccs_active_sessions()` 或同等機制 — 列舉 active sessions

### Terminal 輸出（預設）

```
Session Health Report
═══════════════════════

● abc123  my-project
  Topic: Session Lifecycle 設計
  dup_tool: ● 2    duration: ◐ 150m
  rounds:   ● 18

○ def456  other-project
  Topic: API refactor
  dup_tool: ○ 5    duration: ◐ 180m
  rounds:   ◐ 35

Legend: ● green  ◐ yellow  ○ red
```

符號：`●` green / `◐` yellow / `○` red，加 ANSI 顏色。

### Markdown 輸出（`--md`）

```markdown
## Session Health Report

### 🟢 abc123 — my-project
- **Topic:** Session Lifecycle 設計
- dup_tool: 🟢 2
- duration: 🟡 150m
- rounds: 🟢 18

### 🔴 def456 — other-project
- **Topic:** API refactor
- dup_tool: 🔴 5
- duration: 🟡 180m
- rounds: 🟡 35
```

### JSON 輸出（`--json`）

```json
[
  {
    "session_id": "abc123",
    "project": "my-project",
    "topic": "Session Lifecycle 設計",
    "overall": "green",
    "indicators": {
      "dup_tool": {"level": "green", "value": 2, "threshold": {"yellow": 3, "red": 5}},
      "duration": {"level": "yellow", "value": 150, "unit": "min", "threshold": {"yellow": 120, "red": 240}},
      "rounds": {"level": "green", "value": 18, "threshold": {"yellow": 30, "red": 60}}
    }
  },
  {
    "session_id": "def456",
    "project": "other-project",
    "topic": "API refactor",
    "overall": "red",
    "indicators": {
      "dup_tool": {"level": "red", "value": 5, "threshold": {"yellow": 3, "red": 5}},
      "duration": {"level": "yellow", "value": 180, "unit": "min", "threshold": {"yellow": 120, "red": 240}},
      "rounds": {"level": "yellow", "value": 35, "threshold": {"yellow": 30, "red": 60}}
    }
  }
]
```

### 排序

依 overall 嚴重度排序：red → yellow → green。同級按 `last_ts` 降序。

---

## 七、整合層

### ccs-status

每個 session 行尾加 health badge（`●`/`◐`/`○`）。

### ccs-overview

- `--md`：session 標題旁附 emoji badge（🟢/🟡/🔴）
- `--json`：每個 session 物件中加 `health` 欄位（同 Section 五的 score JSON）

### ccs-orchestrator Skill

overview 結果有 yellow/red session 時，options 中加入：
- 查看 session health 詳情
- 為 `<red-session>` 生成 resume prompt

### 效能考量

MVP 階段，`ccs-status` / `ccs-overview` 整合時，對每個 active session 額外呼叫一次 `_ccs_health_badge()` / `_ccs_health_badge_md()`。這會對每個 session 多跑一次 jq，但 session 數量通常 < 10 個，效能影響可忽略。後續如有需要，再將 health 萃取合併進既有的 jq pipeline 最佳化。

---

## 八、函式介面彙整

```bash
# 資料層
_ccs_health_events()
  # $1: JSONL 檔案路徑
  # → stdout: JSON object（event stream）

# 計算層
_ccs_health_score()
  # stdin: event stream JSON
  # → stdout: JSON object（分級結果）

# 便利函式（給整合用）
_ccs_health_badge()
  # $1: JSONL 檔案路徑
  # → stdout: 單一字元 ●/◐/○（terminal，含 ANSI 顏色）
_ccs_health_badge_md()
  # $1: JSONL 檔案路徑
  # → stdout: emoji 🟢/🟡/🔴（markdown）

# 展示層
ccs-health [session-id] [--md|--json]
  # → stdout: 完整 health report
```

---

## 九、install.sh 更新

- 新增 `ccs-health.sh` 到安裝清單
- 確保 source path 正確
