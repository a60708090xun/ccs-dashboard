# Phase 3 設計文件：跨 Session Feature 進度追蹤

## 概述

將 ccs-dashboard 從「以 session 為單位」延伸為「以 feature/issue 為單位」的進度追蹤。
解決核心痛點：同一件事（例如一個 feature 或 issue）散落在多個 session 中，難以串起來看整體進度。

**方案：B+C 混合** — 輕量 index 檔 + bash 自動推斷 + 手動修正 + Skill 語意增強

## 架構

```
Bash 層（確定性）                    Skill 層（語意增強）
┌──────────────────────┐           ┌──────────────────────┐
│ 自動聚類引擎          │           │ 語意修正建議          │
│ - issue 編號比對      │           │ - 合併誤拆的 feature  │
│ - branch 名稱比對     │           │ - 標記可疑歸類        │
│ - 手動 override      │           │                      │
│                      │  --json   │ 進階狀態摘要          │
│ Feature 摘要 / 時間軸 │ ───────→ │ - 理解「卡在什麼」    │
│ (bash 可獨立運作)     │           │ - 優先順序建議        │
└──────────────────────┘           └──────────────────────┘
```

### 分工原則

- **Bash 層能獨立運作**：不靠 agent 也能看 feature 摘要、時間軸
- **Skill 層是錦上添花**：語意推斷、修正建議、進階分析
- **手動標記最優先**：`overrides.jsonl` 永遠不被自動覆蓋

---

## §1 資料結構

### 資料目錄

```
${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard/
├── features.jsonl        # feature index（cache，可重建）
└── overrides.jsonl       # 手動標記（使用者資料，刪除需確認）
```

### Feature Record（features.jsonl）

每行一個 feature，由聚類引擎每次全量重建：

```jsonl
{"id":"gl65-wtv","label":"GL#65 Write-then-Verify","project":"works/git/specman","sessions":["d24d4ff9","eba3bc08","46a77bff"],"branch":"feat/write-then-verify","status":"in_progress","todos_done":13,"todos_total":14,"last_active_min":120,"last_exchange":"v1.14.0 已安裝。重啟 Claude Code 後生效","git_dirty":10,"updated":"2026-03-18T17:00:00"}
```

| 欄位 | 說明 |
|------|------|
| `id` | feature 唯一 ID（自動生成或手動指定） |
| `label` | 人讀標籤 |
| `project` | 主要專案路徑（ccs-overview 格式） |
| `sessions` | 關聯的 session ID prefix 陣列 |
| `branch` | git branch（如有） |
| `status` | `in_progress` / `completed` / `stale`（根據 todos + 活躍度推斷） |
| `todos_done` / `todos_total` | 跨 session 合併的 todo 進度 |
| `last_active_min` | 最近 session 的活躍分鐘數 |
| `last_exchange` | 最近 session 的最後一句 Claude 回應（截取 100 字） |
| `git_dirty` | uncommitted files 數量 |
| `updated` | index 更新時間 |

### Override Record（overrides.jsonl）

使用者手動標記，聚類引擎最優先讀取：

```jsonl
{"session":"46a77bff","feature":"gl65-wtv","action":"assign"}
{"session":"60a75dec","feature":"gl65-wtv","action":"exclude"}
```

| action | 說明 |
|--------|------|
| `assign` | 強制歸入指定 feature |
| `exclude` | 強制排除出指定 feature |

---

## §2 自動聚類引擎

### 聚類邏輯（優先順序）

1. **Override 優先**：`overrides.jsonl` 中的 assign/exclude
2. **Issue 編號比對**：從 topic 和最近 5 組對話提取 `GL#N`、`#N`、`GH#N`，相同編號聚為同一 feature
3. **同專案 + 同 branch**：非 master/main/develop 的同名 branch 聚為同一 feature
4. **未匹配 session**：不強制歸類，顯示為 "ungrouped"

### Feature ID 生成

- 有 issue 編號 → `gl65-wtv`（issue 編號 + topic 關鍵字 slugify）
- 只有 branch → `specman/feat-write-then-verify`（專案 + branch slugify）
- 都沒有 → 不生成 feature，留在 ungrouped

### Status 推斷

- `in_progress`：有 in_progress todo，或最近 session < 3h
- `completed`：所有 todo 完成，且沒有 active session
- `stale`：最近 session > 24h，有 pending todo

### 重建策略

`ccs-feature` 執行時：
1. 讀 `overrides.jsonl`
2. 掃所有 active session（複用 `ccs-overview` 的 session 收集邏輯）
3. 套用聚類邏輯
4. 寫入 `features.jsonl`（全量覆寫）

`features.jsonl` 是 cache 性質，刪掉下次執行會自動重建。

---

## §3 新增指令

### `ccs-feature [name]` — Feature 進度 View

```bash
ccs-feature                        # 列出所有 feature 摘要
ccs-feature gl65                   # 展開指定 feature 的詳細 view
ccs-feature gl65 --timeline        # 時間軸展開
ccs-feature gl65 -n 5              # 詳細 view 裡顯示 5 個 git commit
ccs-feature --json                 # JSON 輸出（供 Skill 消費）
ccs-feature --md                   # Markdown 輸出
```

**摘要 view（無參數）：**

```markdown
## Features (3)

### 1. 🟢 GL#65 Write-then-Verify [specman]
   Todos: 13/14 | Sessions: 3 | Last: 2h ago
   最後：v1.14.0 已安裝，等 Approve

### 2. 🟡 GL#58 dd-kl-code-obs [specman]
   Todos: 7/7 ✓ | Sessions: 1 | Last: 1d ago
   最後：Rebase 後版號改為 v1.13.1

### 3. 🔵 專案架構長期記憶 [ai/agents]
   Todos: 2/8 | Sessions: 1 | Last: 2m ago
   最後：方案 C 三層框架 + 依賴圖

## Ungrouped Sessions (4)
   60a75dec  happy daemon 狀態 (33m ago)
   1266d974  測試 resume 功能 (20h ago)
   18592f09  ccs-dashboard Phase 2 (0m ago)
   ba4d5b78  Exp-G' WtV 重測 (8m ago)
```

**詳細 view（`ccs-feature gl65`）：**

```markdown
## GL#65 Write-then-Verify
- **專案：** works/git/specman
- **Branch：** feat/write-then-verify
- **狀態：** in_progress
- **Todos：** 13/14 完成，剩 1 pending
  - [ ] Task 14: Merge + Tag + 清理（等 Approve）
- **Git：** master (10 uncommitted files)
- **Sessions (3)：**
  | # | Session | Topic | Last Active |
  |---|---------|-------|-------------|
  | 1 | d24d4ff9 | GL#65 WtV 實作 | 2h ago |
  | 2 | eba3bc08 | Case 008 Exp-G: WtV 實驗 | 1h ago |
  | 3 | 46a77bff | Exp-G JSONL Token 分析 | 41m ago |
- **最後進展：** v1.14.0 已安裝。重啟 Claude Code 後生效
```

**時間軸 view（`ccs-feature gl65 --timeline`）：**

```markdown
## GL#65 Write-then-Verify — Timeline

### 2026-03-18 15:00 — d24d4ff9 GL#65 WtV 實作
  User: 先 install 新版本，我再測試實驗
  Claude: v1.14.0 已安裝。重啟 Claude Code 後生效。

### 2026-03-18 14:20 — eba3bc08 Case 008 Exp-G: WtV 實驗
  User: 先結束，token 分析另開 session
  (todos: 6/6 ✓)

### 2026-03-18 13:40 — 46a77bff Exp-G JSONL Token 分析
  User: 選項 B：新建乾淨 worktree
  (todos: 4/4 ✓)
```

### `ccs-tag` — 手動標記 Session 歸屬

```bash
ccs-tag <session-prefix> <feature-id>              # 歸入
ccs-tag --exclude <session-prefix> <feature-id>    # 排除
ccs-tag --list                                     # 列出所有 override
ccs-tag --clear <session-prefix>                   # 移除某 session 的 override
```

寫入 `overrides.jsonl`，下次 `ccs-feature` 執行時生效。

---

## §4 現有指令修改

### `ccs-overview --git` 增強

加入最近 commit messages，預設 3 個，`-n` 可調：

```bash
ccs-overview --git              # 預設 3 個 commit
ccs-overview --git -n 10        # 最近 10 個
ccs-overview --git -n 0         # 不顯示 commit（只看 status）
```

輸出範例：

```markdown
## Git Status (3 projects)

### 1. ⚠️ specman — master
- **Uncommitted:** 10 files
- **Ahead/Behind:** ↑2 ↓0
- **Recent Commits:**
  - 98b452d 2h ago — feat: implement write-then-verify mode
  - 12a80bc 5h ago — fix: verify-claims.py per-file format
  - 36a8ebe 1d ago — refactor: split skill into modules

### 2. ✅ ai/agents — master
- **Clean**
- **Recent Commits:**
  - abc1234 3d ago — docs: add token efficiency analysis
```

`--json` 模式在 git object 加 `recent_commits` 陣列。

### `ccs-overview --files` — 跨 Session 檔案操作歷史

複用現有 `_ccs_recent_files_md` helper，跨 session 彙整：

```bash
ccs-overview --files              # 按專案分組的寫入操作
ccs-overview --files --all-ops    # 含 Read 操作
ccs-overview --files --json       # JSON 輸出
```

輸出範例：

```markdown
## File Operations (across 12 sessions)

### specman (14 files)
| File | Ops | Sessions | Last |
|------|-----|----------|------|
| src/skills/doc-from-source/SKILL.md | E×3 R×2 | d24d, eba3 | 2h ago |
| src/verify.sh | E×1 W×1 | d24d | 2h ago |

### ai/agents (3 files)
| File | Ops | Sessions | Last |
|------|-----|----------|------|
| docs/specs/memory-design.md | W×1 | a45a | 2m ago |
```

設計要點：
- `Ops` 欄位：`R`=Read, `E`=Edit, `W`=Write, `B`=Bash（僅含檔案路徑的）
- 同檔案跨 session 操作合併為一行
- 按最近操作時間排序
- 預設只顯示寫入操作（E/W），`--all-ops` 含 Read

### `ccs-overview --md` 末尾提示

有 feature 時加一行提示：

```
> 3 features tracked — `ccs-feature` for details
```

---

## §5 Orchestrator Skill 更新

### Command Palette 新增

| Command | Key | Action |
|---------|-----|--------|
| features | f | `ccs-feature --md` — feature 進度總覽 |
| feature N | f N | `ccs-feature --md <name>` — 展開第 N 個 feature |
| timeline N | tl N | `ccs-feature --md <name> --timeline` — 時間軸 |
| files | fl | `ccs-overview --files --md` — 跨 session 檔案操作 |
| tag | tag | 引導使用者執行 `ccs-tag` |

### Skill 語意增強

在 orchestrator skill 的 Interactive phase 中，agent 可以：

1. **語意聚類修正**：讀取 `--json` 後，若發現 ungrouped session 的對話內容與某 feature 相關，建議使用者執行 `ccs-tag` 歸入
2. **進階狀態摘要**：理解「卡在等 MR approve」「blocked by 上游」等需要語境的判斷
3. **優先順序建議**：結合 deadline context + feature status + 活躍度做推斷（僅在使用者要求時）

### Context-Aware Options 新增情境

| 情境 | 建議 options |
|------|-------------|
| overview 後有 features | 加入「看 feature 進度」 |
| feature 摘要後 | 每個 feature 一個「展開 #N」+ 「看時間軸」 |
| feature 詳細 view 後 | 「看時間軸」「回到 feature 列表」「看檔案操作」 |
| 有 ungrouped session 疑似屬於某 feature | 建議「標記 session X 到 feature Y」 |

---

## §6 資料清理

### `install.sh --uninstall` 增強

```bash
# Remove data directory
local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard"
if [ -d "$data_dir" ]; then
  if [ -f "$data_dir/overrides.jsonl" ]; then
    warn "Manual feature tags found: ${data_dir}/overrides.jsonl"
    read -rp "Delete data directory? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] && rm -rf "$data_dir" && ok "Removed ${data_dir}"
  else
    rm -rf "$data_dir"
    ok "Removed ${data_dir}"
  fi
fi
```

- `features.jsonl` 是 cache，直接刪
- `overrides.jsonl` 含手動標記，需使用者確認

---

## §7 實作影響

### 新增檔案

| 檔案 | 說明 |
|------|------|
| `_ccs_feature_cluster` | 聚類引擎（寫入 features.jsonl） |
| `_ccs_feature_md` / `_ccs_feature_json` | feature view 格式化 |
| `_ccs_feature_timeline` | 時間軸 view |
| `_ccs_overview_files` / `_ccs_overview_files_json` | 跨 session 檔案操作彙整 |
| `ccs-feature` | 公開指令 |
| `ccs-tag` | 公開指令 |

### 修改檔案

| 檔案 | 修改 |
|------|------|
| `ccs-dashboard.sh` | 新增 `ccs-feature`、`ccs-tag`、`_ccs_overview_files`；修改 `_ccs_overview_git` 加 commit messages |
| `skills/ccs-orchestrator/SKILL.md` | 新增 Command Palette 項目 + 語意增強說明 + context-aware options |
| `install.sh` | uninstall 加資料目錄清理 |
| `README.md` | 新增指令說明 |

### 複用現有 helper

| Helper | 用途 |
|--------|------|
| `_ccs_recent_files_md` | `--files` view 的基礎 |
| `_ccs_session_row` | feature 聚類時取 session 基本資訊 |
| `_ccs_overview_session_data` | 取 todos、last_exchange、deadline_context |
| `_ccs_topic_from_jsonl` | issue 編號提取來源 |
| `_ccs_resolve_project_path` | 路徑反推 |
