# ccs-review：Session Review 功能設計

> **日期：** 2026-04-03
> **狀態：** 已核可，待實作
> **來源：** ccs-session-review-handoff-2026-03-31.md

---

## 一、目的

提供 session 回顧報告，讓使用者能分享給主管作為 AI 協作進度報告。

核心需求：
- 主管第一眼看到「做了什麼 + 花了多少 + 下一步」
- 工程師可展開看完整對話與統計細節
- CLI 可獨立使用，skill 層提供 LLM 摘要加值

---

## 二、架構決策

| 決策 | 選擇 | 理由 |
|------|------|------|
| 整體架構 | 方案 B：Bash 資料層 + Python 渲染層 | 最大化複用現有 bash 函式，JSON 中間格式解耦兩層 |
| LLM 摘要 | Claude Code subagent + cache | CLI 可獨立運作，skill 層是加值不是必要 |
| HTML 風格 | 混合：上層報告 + 下層 chat bubble | 主管看報告，想看細節展開 bubble |
| HTML 技術 | Python + Jinja2 | template 功能完整，未來 PDF 匯出方便 |
| Token 顯示 | 粗估 token + 字數 + 回合數 | 不同讀者各取所需 |
| 敏感過濾 | 延後實作 | 先聚焦核心功能 |
| 週報 LLM | 統計拼接為主，可選彙整 | 預設便宜快速，需要時才花額外成本 |

---

## 三、系統架構

### 檔案結構

```
ccs-review.sh          # bash 資料層（新模組）
ccs-review-render.py   # python 渲染層
templates/
  review.html          # 單一 session HTML template
  review-weekly.html   # 週報 HTML template
```

### 資料流

```
JSONL
 ↓ (bash: 複用 ccs-core 函式)
ccs-review.sh
 ↓ 輸出 JSON 中間格式 (stdout)
 ├→ --format md   : bash 直接從 JSON 產 markdown
 ├→ --format json : 直接輸出
 └→ --format html : pipe 給 ccs-review-render.py → 單檔 HTML
```

### LLM 摘要 cache

```
~/.local/share/ccs-dashboard/review-cache/
  <session-id>.summary.json
```

- skill 層觸發 subagent → 寫入 cache
- CLI 渲染時檢查 cache → 有就合併進 JSON，沒有就跳過
- cache 有效期 24 小時

---

## 四、JSON 中間格式 Schema

```json
{
  "session_id": "abc123",
  "project": "/path/to/project",
  "model": "claude-opus-4-6",
  "time_range": {
    "start": "2026-04-01T10:00:00",
    "end": "2026-04-01T11:30:00",
    "duration_min": 90
  },
  "stats": {
    "rounds": 42,
    "char_count": 28500,
    "token_estimate": 12000,
    "tool_use": {
      "Read": 23,
      "Edit": 15,
      "Bash": 8,
      "Write": 3,
      "Grep": 5,
      "Agent": 2
    }
  },
  "summary": null,
  "todos": [
    {"status": "completed", "content": "..."}
  ],
  "recent_files": ["R path", "E path"],
  "git_state": {
    "branch": "feat/review",
    "recent_commits": ["..."]
  },
  "conversation": [
    {
      "index": 1,
      "user": "使用者訊息...",
      "assistant": "回覆...",
      "tools": ["Read /a", "Edit /b"]
    }
  ]
}
```

`summary` 欄位在有 cache 時填入：

```json
{
  "completions": ["完成 X 功能", "修正 Y bug"],
  "suggestions": ["建議 Z"],
  "generated_at": "2026-04-01T12:00:00"
}
```

---

## 五、CLI 介面

### 基本命令

```bash
# review 最近一個 session
ccs-review

# review 指定 session
ccs-review <session_id>

# 指定輸出格式（預設 md）
ccs-review <sid> --format md
ccs-review <sid> --format html
ccs-review <sid> --format json

# 指定輸出路徑
ccs-review <sid> -o ./reports/

# 不含 LLM 摘要
ccs-review <sid> --no-summary
```

### 週報模式

```bash
ccs-review --since 2026-03-24 --until 2026-03-31
ccs-review --since 2026-03-24 --until 2026-03-31 --summarize
```

### 輸出規則

- 預設輸出到 stdout（md / json）
- `--format html` 寫檔到當前目錄（無 `-o` 時）
- `-o <dir>` 指定輸出目錄
- 檔名：`<date>-<topic-slug>-review.{md|html}`
- 週報：`<start>-to-<end>-weekly.{md|html}`

### 整合

- `ccs-review.sh` source 到 `ccs-dashboard.sh`，在 `ccs-ops.sh` 之後
- ccs-orchestrator skill 新增 `ccs-review` 路由

---

## 六、HTML 渲染

### 頁面佈局

```
┌──────────────────────────┐
│ Session Review            │
│ [project] — [date]        │
├──────────────────────────┤
│ ┌─ 完成項目摘要 ────────┐ │
│ │ （LLM 生成，           │ │
│ │  無 cache 時不顯示）   │ │
│ └────────────────────────┘ │
│ ┌─ 統計面板 ────────────┐ │
│ │ 耗時 | 回合 | 字數     │ │
│ │ Token 粗估 | 模型      │ │
│ │ Tool Use breakdown     │ │
│ └────────────────────────┘ │
│ ┌─ 改善建議 ────────────┐ │
│ │ （LLM 生成，           │ │
│ │  無 cache 時不顯示）   │ │
│ └────────────────────────┘ │
│ ▶ 任務進度（折疊）        │
│ ▶ 涉及檔案（折疊）       │
│ ▶ Git 狀態（折疊）        │
│ ▶ 完整對話紀錄（折疊）    │
│   chat bubble UI          │
└──────────────────────────┘
```

### 技術細節

- 單檔 HTML：CSS + JS 內嵌，方便傳檔分享
- 折疊：`<details><summary>` 原生 HTML
- Chat bubble：CSS flexbox，user 靠右，assistant 靠左
- Tool badge：assistant bubble 底部顯示工具標籤
- Responsive：CSS media query，手機單欄
- 長訊息截斷：超過 500 字預設折疊，點擊展開

### Jinja2 template 結構

```
templates/review.html
  ├─ block head (CSS 內嵌)
  ├─ block summary (LLM 摘要)
  ├─ block stats (統計面板)
  ├─ block suggestions (改善建議)
  ├─ block details (todos / files / git)
  ├─ block conversation (chat bubble)
  └─ block scripts (JS 內嵌)

templates/review-weekly.html
  ├─ block weekly-summary (彙整)
  └─ block sessions (各 session 折疊卡片)
```

---

## 七、LLM 摘要流程

### 觸發流程（skill 層）

1. 呼叫 `ccs-review <sid> --format json` 取得結構化資料
2. 檢查 cache（有且 < 24hr → 跳過）
3. 從 JSON 取 conversation → 組裝 prompt → 餵 subagent
4. subagent 回傳 completions + suggestions
5. 寫入 cache
6. 呼叫 `ccs-review <sid> --format html -o <path>`（讀到 cache → 完整 HTML）

### Prompt：完成項目摘要

```
你是開發進度報告生成器。以下是 Claude Code session 對話。
提取實際產出，用主管能理解的語言描述。

規則：
- 只列具體完成事項（功能、修正、文件產出）
- 不列 tool call 技術細節
- 每項一句話，動詞開頭
- 半完成項目標註進度百分比

對話：
{conversation}
```

### Prompt：改善建議

```
分析以下對話的溝通模式，找出可改善的地方。

關注：
1. 需求是否一次說清楚
2. 截圖/錯誤是否附文字說明
3. 類似調整是否合併
4. 是否有不必要的確認
5. Tool use 是否有浪費

給出 3 條建議，每條包含：問題 + 改善做法 + 具體例子
```

### Cache 管理

- 路徑：`$XDG_DATA_HOME/ccs-dashboard/review-cache/<session-id>.summary.json`
- 有效期：24 小時
- `--no-summary`：跳過 cache 讀取

---

## 八、週報模式

### 資料結構

```json
{
  "range": {"since": "2026-03-24", "until": "2026-03-31"},
  "aggregate_stats": {
    "total_sessions": 12,
    "total_rounds": 380,
    "total_duration_min": 720,
    "total_char_count": 285000,
    "total_token_estimate": 120000,
    "tool_use_total": {"Read": 230, "Edit": 150}
  },
  "sessions": [{"...individual session JSON..."}],
  "weekly_summary": null
}
```

### 運作方式

- 掃描所有 project 目錄，篩選時間範圍內的 session
- 每個 session 產出個別 JSON，合併成 weekly JSON
- 各 session 的 LLM 摘要取自 cache（沒有就跳過）
- `--summarize`：收集各 session cache 摘要 → 餵 subagent → 產出「本週亮點」（1 次 LLM）

### 週報 HTML

- 頂部：aggregate 統計面板
- 中間：各 session 折疊卡片（展開看個別統計 + 摘要）
- 底部：可選「本週亮點」區塊

---

## 九、實作分批計畫

```
Step 1: CLI + markdown 輸出（純統計）
        → ccs-review.sh 新模組
        → tool use aggregation
        → JSON 中間格式 + markdown 渲染
        → 驗收：3 個 session 統計正確

Step 2: LLM 摘要
        → ccs-orchestrator skill 路由
        → subagent prompt + cache 讀寫
        → 驗收：3 個 session 摘要準確

Step 3: HTML 渲染
        → ccs-review-render.py + Jinja2
        → templates/review.html
        → chat bubble + 折疊 + responsive
        → 驗收：HTML 單檔可開、手機正常

Step 4: 週報模式
        → --since/--until + 合併邏輯
        → templates/review-weekly.html
        → --summarize 可選彙整
        → 驗收：5+ session 合併正確

Step 5: PDF 匯出
        → weasyprint 依賴
        → --format pdf + 列印 CSS
        → 驗收：PDF 排版正常
```

### 依賴關係

```
Step 1 → Step 2 → Step 3 → Step 4 → Step 5
```

每個 Step 獨立可交付，Step 1 完成就可開始使用。

---

## 十、不做的事

1. 即時對話串流（靜態回顧，非 live dashboard）
2. 跨使用者分享平台（輸出本地檔案，手動分享）
3. 對話編輯/匿名化 UI（敏感過濾延後處理）
4. 嵌入式卡片（直接分享完整頁面）
5. 直接打 Anthropic API（LLM 摘要只走 subagent）

---

## 十一、開放問題（延後處理）

1. 敏感資訊過濾範圍與 filter rule set
2. Token 精確計算（目前粗估）
3. cache 清理策略（目前手動 rm）
