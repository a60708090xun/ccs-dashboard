---
name: ccs-orchestrator
description: "MANDATORY for any ccs-* command execution. Never run ccs-* commands via Bash directly — always invoke this skill instead. Triggers on: ccs-status, ccs-overview, ccs-crash, ccs-checkpoint, ccs-recap, ccs-feature, ccs-handoff, ccs-pick, ccs-health, ccs-dispatch, ccs-jobs, ccs-review, ccs-project. Also triggers on: 'checkpoint', 'overview', 'recap', 'sessions', 'crash', 'health', 'handoff', 'dispatch', 'review', 'session review', 'project report', 'project insights', '回顧', '報告', 'weekly report', '週報', '專案報告', '專案洞察', '跑一下checkpoint', '目前狀態', '工作總覽', 'what am I working on', 'show my sessions', 'セッションの状態'. This skill handles output rendering (via _ccs_to_file + Read) so results display correctly in session view."
---

# Code CLI Sessions (CCS) Orchestrator

跨 session 工作指揮台。觀察所有 active Code CLI session (Claude, Gemini 等) 的狀態、待辦事項、git 狀態，並提供互動式導覽。

**定位：觀察者 + 顧問**——只讀取和呈現資訊，不控制其他 session。

## Prerequisites

`ccs-dashboard` 必須已 source 到 shell（`source ~/tools/ccs-dashboard/ccs-dashboard.sh`）。

## Lifecycle

### Phase 1: Welcome（首次觸發）

1. 執行 `ccs-overview --json` 取得結構化資料
2. 執行 `ccs-overview --md` 取得人讀格式
3. 呈現總覽報告（直接輸出 `--md` 結果）
4. 根據資料內容生成 context-aware `<options>` 區塊

### Phase 2: Interactive（後續互動）

使用者透過自然語言或選擇 option 互動，agent 路由到對應指令，呈現結果後再附 context-aware options。

## Command Palette

使用者可用完整指令名或快捷鍵：

| Command | Key | Action |
|---------|-----|--------|
| overview | o | `ccs-overview --md` — 全域工作總覽 |
| sessions | s | `ccs-status --md` — session 列表 |
| detail N | d N | `ccs-pick --md N` — 展開第 N 個 session |
| conversation N | c N | `ccs-pick --md --full N:last` — 最近對話 |
| todos | t | `ccs-overview --md --todos-only` — 跨 session 待辦 |
| git | g | `ccs-overview --git` — 跨專案 git 狀態 |
| features | f | `ccs-feature --md` — feature 進度總覽 |
| feature N | f N | `ccs-feature --md <name>` — 展開第 N 個 feature |
| timeline N | tl N | `ccs-feature --md <name> --timeline` — 時間軸 |
| files | fl | `ccs-overview --files --md` — 跨 session 檔案操作 |
| tag | tag | 引導使用者執行 `ccs-tag`（assign/exclude/list/clear） |
| handoff [dir] | h [dir] | `ccs-handoff [project-dir]` — 產生交接筆記 |
| cleanup | cl | `ccs-cleanup --dry-run` — 殭屍偵測 |
| crash | cr | `ccs-crash --md` — crash-interrupted session 偵測 |
| refresh | r | 重新執行上一個 view |
| checkpoint | cp | `ccs-checkpoint --md` — 進度快照（Done/WIP/Blocked） |
| recap | rc | `ccs-recap --json` + AI analysis — daily work recap |
| health | h | `ccs-health --md` — 顯示 session health report |
| dispatch [dir] "task" | dp | `ccs-dispatch --project <dir> "task"` — 派工到新 session |
| jobs | j | `ccs-jobs` — dispatch 任務歷史 |
| job <id> | | `ccs-jobs <id>` — 單筆結果 |
| review [sid] | rv | `ccs-review [sid]` — session review 報告 |
| review html [sid] | | `ccs-review [sid] --format html -o <path>` — HTML 報告 |
| weekly [since] [until] | wk | `ccs-review --since <date> --until <date>` — 週報 |
| project [path] | pj | `ccs-project [path]` — 專案層級洞察報告 |
| project html [path] | | `ccs-project [path] --format html -o <path>` — HTML 報告 |

## Routing Rules

將使用者輸入路由到 Command Palette：

- 「總覽」「overview」「工作狀態」→ overview
- 「sessions」「列表」→ sessions
- 「展開 #N」「detail N」「看 N」→ detail N
- 「對話」「conversation」→ conversation N
- 「待辦」「todos」「todo」→ todos
- 「git」「git 狀態」→ git
- 「feature」「features」「進度」→ features
- 「時間軸」「timeline」→ timeline N
- 「files」「檔案操作」→ files
- 「tag」「標記」「歸類」→ tag（引導 ccs-tag 操作）
- 「交接」「handoff」→ handoff
- 「清理」「cleanup」「殭屍」→ cleanup
- 「crash」「中斷」「重開機」「crash-detect」→ crash
- 「checkpoint」「進度快照」「standup」「站會」「會議」「更新」「update」「meeting」→ checkpoint
- 「refresh」「r」「重新整理」→ refresh（重跑上一個指令）
- 「排優先順序」「今天該做什麼」「prioritize」→ 根據 JSON 資料做優先順序推斷
- 「recap」「daily recap」「昨天做了什麼」「早安」「morning」「recap --project」→ recap
- 「健康」「health」「退化」「degradation」→ `ccs-health --md`
- 「派工」「dispatch」「跑一下」→ dispatch
- 「任務狀態」「dispatch 結果」「jobs」→ jobs
- 「review」「回顧」「session review」「報告」「review this session」→ review
- 「HTML 報告」「review html」「匯出報告」→ review html
- 「週報」「weekly」「weekly report」「本週報告」→ weekly

數字輸入（如 "1" "2" "3"）→ 在 overview 後等同 `detail N`，在 detail 後等同 `conversation N`。

## Context-Aware Options Logic

每次回應結尾必須附 `<options>` 區塊。選項根據當前 view + 資料內容動態決定：

| 情境 | 建議 options |
|------|-------------|
| 剛看完 overview，有 N 個 active session | 每個 session 一個「展開 #N topic」+ 「跨 session 待辦」 |
| 剛看完 overview，有 features 提示 | 加入「看 feature 進度」 |
| 剛看完 overview，有 ⚠️ git 狀態 | 加入「看 git 狀態」 |
| 剛看完 feature 摘要 | 每個 feature 一個「展開 #N」+ 「看時間軸」 |
| 剛看完 feature 詳細 view | 「看時間軸」「回到 feature 列表」「看檔案操作」 |
| 有 ungrouped session 疑似屬於某 feature | 建議「標記 session X 到 feature Y」 |
| 剛看完 detail #N，有 pending todos | 「看 #N 完整對話」「回到總覽」「看待辦清單」 |
| 剛看完 todos | 「回到總覽」「產生交接筆記」 |
| 有殭屍 process | 加入「清理殭屍」 |
| 沒有 active session | 「看最近所有 session（含 subagent）」 |
| git view 後有 unpushed commits | 提醒使用者哪些專案有 unpushed |
| 剛看完 checkpoint | 「匯出為 markdown 檔」「回到總覽」「看 git 狀態」 |
| 剛看完 recap 分析 | 「匯出為 markdown 檔」「要升級到完整規劃嗎？」 |
| 剛看完 review | 「匯出 HTML」「匯出 PDF」「回到總覽」 |
| 剛看完週報 | 「LLM 彙整本週亮點」「匯出 HTML」「匯出 PDF」 |
| overview 結果有 yellow/red session | 加入「查看 session health 詳情」 |
| overview 結果有 red session | 加入「為 red session 生成 resume prompt」（導向 `ccs-resume-prompt`） |

Options 數量控制在 3-6 個，不超過 7 個。

## Feature Semantic Enhancement

在 Interactive phase 中，agent 可根據 `ccs-feature --json` 資料做語意增強：

1. **語意聚類修正：** 讀取 JSON 後，若 ungrouped session 的 topic 與某 feature 相關，建議使用者用 `ccs-tag` 歸入
2. **進階狀態摘要：** 理解「等 MR approve」「blocked by 上游」等需要語境的判斷
3. **優先順序建議：** 結合 deadline context + feature status + 活躍度推斷（僅在使用者要求時）

## Agent Behavior

1. **先 JSON 後呈現：** 內部先跑 `--json` 做判斷（需要哪些 options、有無殭屍等），再跑 `--md` 取人讀格式呈現。如果 `--md` 已包含所需資訊，可省略 `--json` 步驟。
2. **單次不超過 2 個 Bash 呼叫：** 避免 token 浪費。
3. **不主動分析或建議：** 除非使用者問「排優先順序」或「今天該做什麼」。
4. **優先順序推斷規則**（僅在使用者要求時）：
   - 有明確 deadline 的排最前
   - in_progress 優先於 pending
   - 最近活躍的 session 優先於閒置的
5. **Refresh：** 使用者說「refresh」「r」「重新整理」→ 重跑上一個指令。靠 conversation context 記住上一個 view。
6. **原文輸出，禁止摘要：** `Read` 檔案後必須**逐字貼出**完整 `--md` 內容，禁止刪減、改寫、或用自己的話重新整理。即使內容很長也不得省略。只允許在原文**之後**加一行 actionable 備註（如「有 2 個 unpushed commit」）。
7. **Tool output 必須呈現在 agent response：** Bash tool 的 output 對使用者是收合的，使用者不會展開查看。所有 ccs-* 指令必須透過 `_ccs_to_file` 執行，將 stdout 導到 `$_CCS_CACHE_DIR/<name>.md`，再用 `Read` 讀取檔案內容貼在 agent response 中。範例：
   ```bash
   source ~/tools/ccs-dashboard/ccs-dashboard.sh && \
     _ccs_to_file "$_CCS_CACHE_DIR/overview.md" \
     ccs-overview --md
   ```
   Bash result 只有一行確認訊息，agent 再 `Read` 該檔案輸出給使用者。絕對不要只說「結果已在上面呈現」。

### Recap 流程

1. 執行 `ccs-recap --json` 取得結構化數據
2. 列出有活動的專案，用 `<options>` 問使用者要看哪些（預設全選）
   - YOLO mode 下直接全選，不提問
3. 對每個 pending/in_progress session，用 `_ccs_get_pair` 讀取最後 2-3 對話
4. 輸出分析：
   - 數據摘要（含完成項重點：從 `completed_items` 取 per-project top highlights）
   - 各工作項分析（進展/卡住原因）
   - 優先順序建議（deadline > 卡住需決策 > 接近完成 > 低優先）
5. 用 `<options>` 問：「要升級到完整規劃嗎？」
   - 是 → 生成今日工作計畫（任務/專案/建議時段/說明）
   - 否 → 結束

### Review 流程

Session review 產生進度報告，可分享給主管。有兩種模式：

**單一 session review：**

1. 執行 `ccs-review <sid> --format json` 取得結構化資料
2. 檢查 LLM summary cache（`~/.local/share/ccs-dashboard/review-cache/<sid>.summary.json`）
3. 若無 cache 或已過期（>24h）：
   - 從 JSON 取 `conversation` 欄位
   - 派 subagent 生成兩段摘要：
     a. **完成項目摘要**（prompt: 提取具體產出，動詞開頭，標註半完成%）
     b. **改善建議**（prompt: 分析溝通模式，3 條建議含具體例子）
   - 寫入 cache：`_ccs_review_cache_write "<sid>" '<json>'`（透過 Bash 呼叫）
4. 執行 `ccs-review <sid> --format md` 呈現結果
5. 用 `<options>` 問：「要匯出 HTML？」「要匯出 PDF？」「回到總覽」

**週報模式：**

1. 執行 `ccs-review --since <date> --until <date> --format md`
2. 呈現結果
3. 用 `<options>` 問：「要 LLM 彙整本週亮點？」「匯出 HTML」「匯出 PDF」
4. 若選 LLM 彙整 → 收集各 session cache 摘要 → 派 subagent → 呈現

### Project 流程

專案層級洞察報告，結合投入成本、功能進度、開發節奏、程式碼變動。

1. 執行 `ccs-project [path] --format json` 取得結構化資料
2. 檢查 insights cache（`~/.local/share/ccs-dashboard/project-cache/<encoded>.insights.json`）
3. 若無 cache 或已過期（>24h）：
   - 從 JSON 取 `sessions`、`features`、`code_changes`、`rhythm`
   - 派 subagent 生成洞察：
     a. **健康度摘要**（prompt: 綜合所有維度，3-5 句整體評估）
     b. **重複問題**（prompt: 從 session topics 和 code changes 找重複模式）
     c. **改善建議**（prompt: 基於節奏和問題模式，3 條可行建議）
   - 組成 insights JSON：`{"highlights":["一句話重點1","一句話重點2",...],"health_summary":"...","recurring_issues":[...],"hotspot_files":[...],"suggestions":[...],"generated_at":"..."}`
   - `highlights` 是 3-5 個 bullet points，每條一句話（≤30 字），用於摘要層快速瀏覽
   - 寫入 cache：
     ```bash
     mkdir -p "$(_ccs_data_dir)/project-cache"
     echo '<insights json>' > "$(_ccs_data_dir)/project-cache/<encoded>.insights.json"
     ```
4. 執行 `ccs-project [path] --format md` 呈現結果
5. 用 `<options>` 問：「要匯出 HTML？」「回到總覽」
