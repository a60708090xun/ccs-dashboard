# CCS Orchestrator 設計文件

## 概述

將 ccs-dashboard 從「純 terminal 工具」延伸為「Agent 可消費的 session 觀察平台」。
設計一個 orchestrator session：使用者開一個「指揮台」session，agent 能查看所有其他 session 的狀態、
對話摘要、TodoWrite 進度，並整合跨 session 的待辦事項，推斷優先順序。

**定位：觀察者 + 顧問**，不控制其他 session。

## 架構：方案 B — bash 彙整指令 + Skill

```
ccs-overview (新 bash 指令)
  → 掃描所有 active session 的 JSONL
  → 提取：session 狀態、topic、todos、最近對話摘要、deadline 關鍵字
  → 輸出結構化 Markdown 或 JSON

ccs-orchestrator (Skill)
  → 呼叫 ccs-overview 取得精簡資料
  → Agent 在精簡資料上做推斷、互動、路由
  → 動態附上 context-aware options
```

### 分工

| ccs-overview（bash）| ccs-orchestrator（Skill）|
|---|---|
| 資料收集 + 結構化 | 呈現 + 互動 + 推斷 |
| 掃 JSONL、提取 todos | 自然語言路由到指令 |
| 提取 deadline 關鍵字原文 | 判斷優先順序 |
| 輸出 Markdown / JSON | 動態生成 options |
| Terminal 也能獨立用 | 只在 Claude Code 內 |

### 設計借鏡

- **OpenClaw Dashboard-v2：** 模組化 views（Overview/Sessions/Agent/Chat/Config）→ 對應到 Skill 的互動 views
- **Lobster typed pipeline：** `--json` 結構化輸出，讓 agent 確定性解析
- **LobsterBoard Command Palette：** 首次顯示完整 menu，之後 context-aware options

---

## Part 1：`ccs-overview` 指令

### 用途

一次產生跨 session 的工作總覽，供人直接看或給 agent 消費。

### 呼叫方式

```bash
ccs-overview              # Terminal ANSI 輸出（預設，與 ccs-status 慣例一致）
ccs-overview --md         # Markdown 輸出（給 Skill / Happy 網頁版）
ccs-overview --json       # JSON 輸出（給 Skill 做結構化推斷）
ccs-overview --git        # 跨專案 git 狀態
ccs-overview --todos-only # 只輸出跨 session 待辦彙整
```

> **Note:** `--json` 從 Phase 1 就實作，Skill 的 context-aware options 需要結構化資料做判斷。
> Markdown 模式供人讀，JSON 模式供 agent 消費。

### 輸出格式（Markdown）

```markdown
# Work Overview (2026-03-18 14:30)

## Active Sessions (3)

### 1. 🟢 specman — Skill 架構重構
- **Session:** a1b2c3d4 | specman | 5m ago
- **Git:** feature/skill-refactor (3 uncommitted files)
- **Last Exchange:**
  - **User:** 把 doc-from-source 的 verify 改成 post-hoc 模式
  - **Claude:** 已修改 verify 流程，改為先寫後驗。待跑 regression test 確認
- **Todos:**
  - [x] 拆分 SKILL.md 為模組化結構
  - [~] 更新 doc-from-source 的 verify 邏輯
  - [ ] 跑 regression test
- **Context:** 使用者提到週五前要完成 MR review

### 2. 🟡 ai_agents — Token 分析文件
- **Session:** e5f6g7h8 | ai_agents | 45m ago
- **Git:** master (clean)
- **Last Exchange:**
  - **User:** 開始寫 Gemini CLI 的 token 效率章節
  - **Claude:** 已建立章節骨架，待填入 Gemini 的 cache 機制分析
- **Todos:**
  - [~] 撰寫 Gemini CLI 的 token 效率章節
- **Context:** 無明確 deadline

### 3. 🔵 ccs-dashboard — CCS Dashboard 開發
- **Session:** i9j0k1l2 | tools/ccs-dashboard | 3h ago
- **Git:** master (1 uncommitted file)
- **Last Exchange:**
  - **User:** 想加 git status view
  - **Claude:** 已加入設計，留 commit message 和檔案歷史作為 future work
- **Todos:** (none)
- **Context:** 正在發想 orchestrator 功能

## Pending Todos (cross-session)

| # | Task | Project | Status | Urgency |
|---|------|---------|--------|---------|
| 1 | 跑 regression test | specman | pending | 🔴 週五前 |
| 2 | 更新 verify 邏輯 | specman | in_progress | 🔴 週五前 |
| 3 | Gemini CLI token 章節 | ai_agents | in_progress | ⚪ 無 deadline |

## Zombie Processes

(none)
```

### 設計要點

- **Last Exchange：** 呼叫 `_ccs_get_pair` 取最後一組非 meta prompt-response，自行截取（User: 1 行 120 字、Claude: 2 行 200 字），不直接複用 `_ccs_conversation_md`（截取粒度不同）
- **Context 欄位：** 從最近 **5 組**對話中用 jq 提取含 deadline 關鍵字的句子（`deadline`、`before`、`週`、`月`、`by`、`due`、`urgent`、`ASAP`），原文截取。上限 5 組以平衡效能與涵蓋率
- **Urgency 判定：** bash 只負責提取原文，**不做 AI 推斷**——排優先順序交給 agent
- **Pending Todos：** 每個 session 只取最後一次 `TodoWrite` 呼叫（`TodoWrite` 是全量覆寫語意），跨 session 彙整時附上 project 名稱。不做跨 session 去重（不同 session 的同名 todo 可能語意不同）
- **Zombie Processes：** overview 只顯示殭屍數量和總 RAM，不列詳細清單（詳細清單用 `ccs-cleanup --dry-run`），避免與 `ccs-status` 重複
- `--json` 輸出結構化 JSON，欄位與 Markdown 一一對應

### 路徑反推

從 JSONL 目錄名還原實際 filesystem path 時，不能用簡單 `sed 's/-/\//g'`（專案名含 `-` 會被錯誤展開）。

**正確做法：** 使用 `$HOME` + 目錄名的第一段做前綴比對，找到實際存在的最長路徑：

```bash
# 目錄名範例：-home-user-tools-ccs-dashboard
# 1. 還原前綴 → $HOME/
# 2. 剩餘部分逐段嘗試：tools-ccs-dashboard → tools/ccs-dashboard? tools/ccs/dashboard?
# 3. 選擇實際存在的路徑
_ccs_resolve_project_path() {
  local encoded="$1"
  # 移除開頭的 -，轉回 /
  local raw="/${encoded#-}"
  # 逐段嘗試：從最長 path 開始，檢查是否存在
  local path="$raw"
  while [[ "$path" == *-* ]]; do
    # 嘗試把最後一個 - 換成 /
    local try="${path%-*}/${path##*-}"
    [ -d "$try" ] && { echo "$try"; return 0; }
    path="$try"
  done
  # fallback: 全部 - 換 /
  echo "/${encoded//[-]/\/}" | sed 's|^/||; s|^|/|'
}
```

### Git Status View（`--git`）

```markdown
## Git Status (3 projects)

### 1. ⚠️ specman — feature/skill-refactor
- **Uncommitted:** 3 files (2 modified, 1 untracked)
- **Ahead/Behind:** ↑2 ↓0 (2 commits unpushed)
- **Stash:** 1 entry
- **Modified:** src/skills/doc-from-source/SKILL.md, src/verify.sh, tmp/test-output.log

### 2. ✅ ai_agents — master
- **Clean**

### 3. ⚠️ tools/ccs-dashboard — master
- **Uncommitted:** 1 file (1 modified)
- **Ahead/Behind:** ↑1 ↓0
- **Modified:** ccs-dashboard.sh
```

- 只掃有 active/recent session 的 project 目錄，不掃全機器
- `⚠️` = 有未 commit 或 unpushed，`✅` = clean
- 從 JSONL 目錄名反推實際路徑（`-home-user-projects-specman` → `~/projects/specman`）
- 每目錄跑 `git status --porcelain` + `git rev-list --left-right @{u}...HEAD` + `git stash list`

---

## Part 2：`ccs-orchestrator` Skill

### 生命週期

```
Phase 1: Welcome（首次觸發）
  → 跑 ccs-overview --md
  → 呈現總覽報告
  → 顯示完整 Command Palette menu
  → 附上 context-aware options（基於當前狀態）

Phase 2: Interactive（後續互動）
  → 使用者自然語言或選 option
  → Agent 路由到對應 ccs 指令
  → 呈現結果
  → 附上 context-aware options（根據剛看的東西建議下一步）

Phase 3: Auto-trigger（未來，blocked by upstream）
  → 需要 Claude Code 提供 session-start hook 機制
  → 目前無此功能，追蹤 upstream 進度
```

### Command Palette

| Command | Shortcut | Action |
|---------|----------|--------|
| overview | o | `ccs-overview --md` — 全域工作總覽 |
| sessions | s | `ccs-status --md` — session 列表 |
| detail N | d N | `ccs-pick --md N` — 展開第 N 個 session |
| conversation N | c N | `ccs-pick --md --full N:last` — 最近對話 |
| todos | t | `ccs-overview --md --todos-only` — 跨 session 待辦 |
| git | g | `ccs-overview --git` — 跨專案 git 狀態 |
| handoff [dir] | h [dir] | `ccs-handoff [project-dir]` — 產生交接筆記（接受 project 目錄或從 overview 的 session 列表推導） |
| cleanup | cl | `ccs-cleanup --dry-run` — 殭屍偵測 |
| refresh | r | 重新執行上一個 view |

### Context-Aware Options 邏輯

Agent 根據當前 view + 資料內容動態選擇建議：

| 情境 | 建議 options |
|------|-------------|
| 剛看完 overview，有 N 個 active session | [展開 #1 xxx] [展開 #2 xxx] [看跨 session 待辦] |
| 剛看完 detail #N，有 pending todos | [看 #N 的完整對話] [回到總覽] [看待辦清單] |
| 剛看完 todos，有殭屍 process | [清理殭屍] [回到總覽] [產生交接筆記] |
| 沒有 active session | [看最近 48 小時所有 session] [看 archived sessions] |
| overview 後有 ⚠️ git 狀態 | options 裡加 [看 git 狀態] |
| git view 後有 unpushed commits | 提醒使用者 |

### Agent 行為規範

1. 每次回應結尾附 `<options>` 區塊，選項基於當前 context
2. 不主動分析或建議，除非使用者問「排優先順序」或「今天該做什麼」
3. 優先順序推斷規則：
   - 有明確 deadline 的排最前
   - in_progress 優先於 pending
   - 最近活躍的 session 優先於閒置的
4. Skill 內部先跑 `--json` 取結構化資料做判斷，再跑 `--md` 取人讀格式呈現（或直接從 JSON 格式化）
5. 單次不超過 2 個 Bash 呼叫，避免 token 爆炸
6. 使用者說「refresh」或「r」→ 重跑上一個指令（靠 conversation context 記住，非 persistent state，compaction 後可能遺失）

---

## Future Work

- [ ] 跨 session 檔案操作歷史 view（agent 改了哪些檔案）— 複用 `_ccs_recent_files_md`
- [ ] Git view 加上最近 commit messages（了解進度）
- [ ] Phase 3 auto-trigger hook（blocked by upstream：Claude Code 無 session-start hook）
- [ ] MCP server 包裝（方案 C 升級路徑）— `ccs-overview --json` 的邏輯可直接搬入

---

## 實作分期

### Phase 1: `ccs-overview` 指令
- 新增 `_ccs_resolve_project_path` helper 到 `ccs-core.sh`
- 新增 `ccs-overview` 到 `ccs-dashboard.sh`
- 支援 `--md`、`--json`、`--git`、`--todos-only`（預設 terminal ANSI）
- 複用現有 helpers：`_ccs_session_row`、`_ccs_get_pair`、`_ccs_todos_md`
- `--json` 在 Phase 1 就實作（Skill 需要）

### Phase 2: `ccs-orchestrator` Skill
- 建立 `~/.claude/skills/ccs-orchestrator/SKILL.md`
- Command Palette + context-aware options
- 自然語言路由
- Skill 內部用 `--json` 判斷，用 `--md` 或自行格式化呈現

### Phase 3: Auto-trigger（blocked by upstream）
- 等 Claude Code 提供 session-start hook
- 屆時可自動觸發 overview
