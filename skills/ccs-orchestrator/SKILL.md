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
| handoff [dir] | h [dir] | `ccs-handoff [project-dir]` — 產生交接筆記 |
| cleanup | cl | `ccs-cleanup --dry-run` — 殭屍偵測 |
| refresh | r | 重新執行上一個 view |

## Routing Rules

將使用者輸入路由到 Command Palette：

- 「總覽」「overview」「工作狀態」→ overview
- 「sessions」「列表」→ sessions
- 「展開 #N」「detail N」「看 N」→ detail N
- 「對話」「conversation」→ conversation N
- 「待辦」「todos」「todo」→ todos
- 「git」「git 狀態」→ git
- 「交接」「handoff」→ handoff
- 「清理」「cleanup」「殭屍」→ cleanup
- 「refresh」「r」「重新整理」→ refresh（重跑上一個指令）
- 「排優先順序」「今天該做什麼」「prioritize」→ 根據 JSON 資料做優先順序推斷

數字輸入（如 "1" "2" "3"）→ 在 overview 後等同 `detail N`，在 detail 後等同 `conversation N`。

## Context-Aware Options Logic

每次回應結尾必須附 `<options>` 區塊。選項根據當前 view + 資料內容動態決定：

| 情境 | 建議 options |
|------|-------------|
| 剛看完 overview，有 N 個 active session | 每個 session 一個「展開 #N topic」+ 「跨 session 待辦」 |
| 剛看完 overview，有 ⚠️ git 狀態 | 加入「看 git 狀態」 |
| 剛看完 detail #N，有 pending todos | 「看 #N 完整對話」「回到總覽」「看待辦清單」 |
| 剛看完 todos | 「回到總覽」「產生交接筆記」 |
| 有殭屍 process | 加入「清理殭屍」 |
| 沒有 active session | 「看最近所有 session（含 subagent）」 |
| git view 後有 unpushed commits | 提醒使用者哪些專案有 unpushed |

Options 數量控制在 3-6 個，不超過 7 個。

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
