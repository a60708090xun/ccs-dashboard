---
name: ccs-orchestrator
description: Cross-session work orchestrator — view all active Claude Code sessions, todos, git status, and navigate between session details. Use when user wants a work overview, session management, task prioritization, or handoff notes. Trigger phrases include ccs, orchestrator, sessions overview, work dashboard, what am I working on.
---

# CCS Orchestrator

跨 session 工作指揮台。觀察所有 active Claude Code session 的狀態、待辦事項、git 狀態，並提供互動式導覽。

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
| refresh | r | 重新執行上一個 view |
| checkpoint | cp | `ccs-checkpoint --md` — 進度快照（Done/WIP/Blocked） |
| recap | rc | `ccs-recap --json` + AI analysis — daily work recap |

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
- 「checkpoint」「進度快照」「standup」「站會」「會議」「更新」「update」「meeting」→ checkpoint
- 「refresh」「r」「重新整理」→ refresh（重跑上一個指令）
- 「排優先順序」「今天該做什麼」「prioritize」→ 根據 JSON 資料做優先順序推斷
- 「recap」「daily recap」「昨天做了什麼」「早安」「morning」「recap --project」→ recap

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
6. **輸出簡潔：** 直接輸出 `--md` 結果，不加額外解釋或 wrapper。只在有 actionable 資訊時加簡短備註（如「有 2 個 unpushed commit」）。

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
