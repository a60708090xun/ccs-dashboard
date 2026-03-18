# Phase 3: 跨 Session Feature 進度追蹤 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 ccs-dashboard 能以 feature/issue 為單位追蹤跨 session 進度，包含自動聚類、手動修正、摘要/時間軸 view。

**Architecture:** B+C 混合 — bash 層做確定性聚類 + 狀態摘要（可獨立運作），skill 層做語意增強（錦上添花）。資料存 `${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard/`。

**Tech Stack:** bash 4+, jq, git

**Spec:** `docs/specs/2026-03-19-phase3-feature-tracking-design.md`

---

## File Structure

| 檔案 | 角色 | 修改類型 |
|------|------|----------|
| `ccs-dashboard.sh` | 新增 `ccs-feature`、`ccs-tag`、聚類引擎、files view、git commits 增強 | Modify |
| `skills/ccs-orchestrator/SKILL.md` | 新增 Command Palette 項目 + 語意增強 + context-aware options | Modify |
| `install.sh` | uninstall 加資料目錄清理 | Modify |
| `README.md` | 新增指令說明 | Modify |

所有新函式加在 `ccs-dashboard.sh` 內（與現有慣例一致，不新建檔案）。

> **Note:** 本 plan 中的行號為撰寫時的參考值，實作時因前面 task 插入程式碼會偏移，請以函式名搜尋定位。

> **Feature ID 格式：** spec 範例中的 `gl65-wtv` 為簡化示意，實際實作統一使用 `<project>/<source><number>` 格式（如 `specman/gl65`），加專案前綴避免跨專案碰撞。

---

## Task 0: 抽取共用 session 收集邏輯

**Files:**
- Modify: `ccs-dashboard.sh` — 將 `ccs-overview()` 內的 session 收集迴圈（約 lines 1977-2022）抽為 `_ccs_collect_sessions`

`ccs-overview` 和 `ccs-feature` 都需要收集 active sessions，抽成共用 helper 避免重複 45 行。

- [ ] **Step 1: 新增 `_ccs_collect_sessions` 函式**

將 `ccs-overview()` 內從 `local sessions_dir=` 到 `done < <(find ...)` 的迴圈抽出。
簽名：`_ccs_collect_sessions [-a|--all] out_files out_projects out_rows`
（3 個 nameref 輸出陣列 + optional `--all` flag）

- [ ] **Step 2: 修改 `ccs-overview()` 改為呼叫 `_ccs_collect_sessions`**

```bash
local -a session_files=() session_projects=() session_rows=()
_ccs_collect_sessions ${show_all:+--all} session_files session_projects session_rows
```

- [ ] **Step 3: 驗證 `ccs-overview` 行為未改變**

```bash
ccs-overview --md
ccs-overview --json
ccs-overview --git
ccs-overview --todos-only
```

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "refactor: extract _ccs_collect_sessions from ccs-overview"
```

---

## Task 1: 聚類引擎 `_ccs_feature_cluster`

**Files:**
- Modify: `ccs-dashboard.sh` — 在 `ccs-overview()` 前新增函式

這是核心函式，負責掃描 active sessions、套用聚類邏輯、寫入 `features.jsonl`。

- [ ] **Step 1: 新增 `_ccs_data_dir` helper**

```bash
_ccs_data_dir() {
  local dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard"
  mkdir -p "$dir"
  echo "$dir"
}
```

- [ ] **Step 2: 新增 `_ccs_feature_cluster` 函式骨架**

函式簽名：`_ccs_feature_cluster session_files session_projects session_rows`
（接收與 `_ccs_overview_md` 相同的 nameref 陣列）

邏輯順序：
1. 讀 `overrides.jsonl`（容錯：malformed line → skip + warn）
2. 遍歷 session 陣列，對每個 session：
   a. 檢查 override → 若有 assign，歸入指定 feature
   b. 從 topic 提取 issue 編號（regex: `(GL|GH)#[0-9]+`）→ 歸入 `<project>/<source><number>`
   c. 檢查 git branch（非 master/main/develop）→ 歸入 `<project>/<branch-slug>`
   d. 以上都不匹配 → ungrouped
3. 對每個 feature，彙整：sessions、todos（union）、last_active_min、last_exchange、git 狀態
4. 推斷 status（in_progress > stale > completed > idle）
5. 寫入 `features.jsonl`

- [ ] **Step 3: 實作 issue 編號提取**

```bash
# Extract first issue ref from topic string
# Returns: "gl65" or "gh12" or empty
_ccs_extract_issue_ref() {
  local topic="$1"
  echo "$topic" | grep -oiP '(GL|GH)#\d+' | head -1 | tr '[:upper:]' '[:lower:]' | tr -d '#'
}
```

- [ ] **Step 4: 實作 branch slug 生成**

```bash
# Convert branch name to slug: feat/write-then-verify → feat-write-then-verify
_ccs_branch_slug() {
  echo "$1" | tr '/' '-' | tr '[:upper:]' '[:lower:]'
}
```

- [ ] **Step 5: 實作 overrides 讀取（含容錯）**

```bash
_ccs_read_overrides() {
  local overrides_file="$(_ccs_data_dir)/overrides.jsonl"
  [ ! -f "$overrides_file" ] && return 0
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if ! echo "$line" | jq -e . &>/dev/null; then
      echo "ccs: warning: overrides.jsonl line $line_num: malformed JSON, skipping" >&2
      continue
    fi
    echo "$line"
  done < "$overrides_file"
}
```

- [ ] **Step 6: 實作完整聚類邏輯**

核心迴圈：遍歷 sessions → 分配到 features → 彙整每個 feature 的統計資料。
使用 bash associative arrays 做 feature → sessions 映射。

- [ ] **Step 7: 實作 status 推斷**

```bash
# Inputs: todos_done, todos_total, last_active_min, has_in_progress_todo
# Output: in_progress | stale | completed | idle
_ccs_feature_status() {
  local todos_done=$1 todos_total=$2 last_min=$3 has_ip=$4
  if [ "$has_ip" = "true" ] || [ "$last_min" -lt 180 ]; then
    echo "in_progress"
  elif [ "$last_min" -gt 1440 ] && [ "$todos_total" -gt "$todos_done" ]; then
    echo "stale"
  elif [ "$todos_total" -gt 0 ] && [ "$todos_done" -eq "$todos_total" ] && [ "$last_min" -ge 180 ]; then
    echo "completed"
  else
    echo "idle"
  fi
}
```

- [ ] **Step 8: 寫入 features.jsonl**

用 jq 組裝每個 feature record，寫入 `$(_ccs_data_dir)/features.jsonl`（全量覆寫）。
寫入失敗時：emit warning 到 stderr，保留記憶體中的資料供當次渲染使用（不中斷）。

- [ ] **Step 9: 驗證聚類引擎**

```bash
source ~/tools/ccs-dashboard/ccs-dashboard.sh
# 手動呼叫內部函式測試
_ccs_extract_issue_ref "GL#65 Write-then-Verify 實作"  # 預期: gl65
_ccs_extract_issue_ref "專案架構設計"                    # 預期: (empty)
_ccs_branch_slug "feat/write-then-verify"                # 預期: feat-write-then-verify
```

- [ ] **Step 10: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add feature clustering engine (_ccs_feature_cluster)"
```

---

## Task 2: `ccs-feature` 指令 — 摘要 View

**Files:**
- Modify: `ccs-dashboard.sh` — 新增 `ccs-feature`、`_ccs_feature_md`、`_ccs_feature_json`、`_ccs_feature_terminal`

- [ ] **Step 1: 新增 `ccs-feature` 入口函式**

解析參數：`--md`、`--json`、`--timeline`、`-n N`、feature name。
無參數 → 摘要 view。有 name → 詳細 view。
預設輸出為 Terminal ANSI（與 `ccs-overview` 一致），Skill 用 `--md` 或 `--json`。

入口函式必須：
1. 呼叫 `_ccs_collect_sessions` 收集 active sessions
2. 呼叫 `_ccs_feature_cluster` 做聚類
3. 根據參數分派到摘要/詳細/時間軸 view

- [ ] **Step 2: 實作 `_ccs_feature_md` 摘要 view**

格式參考 spec §3 的摘要 view 範例。遍歷 `features.jsonl`，每個 feature 輸出：
- 狀態 icon + label + project
- Todos done/total + sessions count + last active
- 最後進展（截取 last_exchange）
- Ungrouped sessions 列表

- [ ] **Step 3: 實作 `_ccs_feature_json` 摘要 view**

直接輸出 `features.jsonl` 的內容加上 ungrouped sessions。

- [ ] **Step 4: 實作 `_ccs_feature_terminal` 摘要 view**

ANSI 版本，用顏色區分 status：
- 🟢 / green → in_progress
- 🟡 / yellow → stale
- ✅ / dim → completed
- 🔵 / blue → idle

- [ ] **Step 5: 驗證摘要 view**

```bash
ccs-feature           # terminal 版
ccs-feature --md      # markdown 版
ccs-feature --json    # JSON 版
```

確認有 features 被正確聚類，ungrouped sessions 分開顯示。

- [ ] **Step 6: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add ccs-feature summary view"
```

---

## Task 3: `ccs-feature` 指令 — 詳細 View + 時間軸

**Files:**
- Modify: `ccs-dashboard.sh` — 新增 `_ccs_feature_detail_md`、`_ccs_feature_timeline_md`（+ 對應 terminal 版本）

> Detail 和 timeline 的 terminal 版本可直接複用 md 版本的邏輯加 ANSI color，或先只實作 md 版、terminal 暫時 fallback 到 md。兩種都可接受。

- [ ] **Step 1: 實作 `_ccs_feature_detail_md`**

指定 feature name 後顯示：
- 專案、branch、status
- Todos 列表（合併所有 session 的最後 TodoWrite）
- Git 狀態 + 最近 N 個 commit（預設 3，`-n` 可調）
- Sessions 表格（session ID、topic、last active）
- 最後進展

需呼叫 `_ccs_overview_session_data` 取各 session 資料，`git log --oneline -N` 取 commits。

- [ ] **Step 2: 實作 `_ccs_feature_timeline_md`**

按時間排序所有 session，每個 session 輸出：
- 時間戳 + session ID + topic
- 最後一組 user/claude 對話（呼叫 `_ccs_get_pair`）
- Todos 摘要（done/total）

- [ ] **Step 3: 驗證詳細 view + 時間軸**

```bash
ccs-feature --md <some-feature-id>
ccs-feature --md <some-feature-id> --timeline
ccs-feature --md <some-feature-id> -n 5
```

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add ccs-feature detail and timeline views"
```

---

## Task 4: `ccs-tag` 指令

**Files:**
- Modify: `ccs-dashboard.sh` — 新增 `ccs-tag`

- [ ] **Step 1: 實作 `ccs-tag` 入口函式**

```bash
ccs-tag() {
  case "${1:-}" in
    --list)     # 讀取並顯示 overrides.jsonl
    --exclude)  # shift, 寫入 exclude record
    --clear)    # 移除指定 session 的 override（可選 feature-id）
    --help|-h)  # help text
    *)          # 預設：assign，$1=session-prefix $2=feature-id
  esac
}
```

- [ ] **Step 2: 實作 assign/exclude 寫入**

驗證 session prefix 存在（在 active sessions 中找得到），append 到 `overrides.jsonl`。

- [ ] **Step 3: 實作 `--clear`**

`ccs-tag --clear <session>` → 移除該 session 所有 override
`ccs-tag --clear <session> <feature>` → 移除特定 override
用 temp file + mv 過濾（比 sponge 更 atomic，信號中斷不會損毀原檔）。

- [ ] **Step 4: 實作 `--list`**

讀取 `overrides.jsonl`，格式化輸出。

- [ ] **Step 5: 驗證**

```bash
ccs-tag <session-prefix> <feature-id>     # assign
ccs-tag --list                            # 確認寫入
ccs-feature --md                          # 確認聚類結果改變
ccs-tag --clear <session-prefix>          # 移除
ccs-tag --list                            # 確認移除
```

- [ ] **Step 6: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add ccs-tag for manual feature assignment"
```

---

## Task 5: `ccs-overview --git` 增強 — 加入 Commit Messages

**Files:**
- Modify: `ccs-dashboard.sh` — `_ccs_overview_git`（搜尋函式名定位）、`_ccs_overview_git_json`、`ccs-overview` arg parser

**參數串接鏈：** `-n` 值需從 arg parser 一路傳到底層函式：
1. `ccs-overview` arg parser → `local git_commits=3` → 傳給 `_ccs_overview_git`
2. `_ccs_overview_git` 簽名：`local -n _files=$1 _projects=$2; local mode="$3" git_commits="${4:-3}"`
3. `_ccs_overview_git` → `_ccs_overview_git_json unique_dirs "$git_commits"`
4. 呼叫端：`_ccs_overview_git session_files session_projects "$mode" "$git_commits"`

- [ ] **Step 1: 修改 `ccs-overview` arg parser**

在 while loop 的 `*)` catch-all **之前**加入 `-n` 處理：

```bash
-n) git_commits="${2:-3}"; shift 2 ;;
```

- [ ] **Step 2: 修改 `_ccs_overview_git` 簽名和呼叫端**

更新函式簽名接收第 4 個參數 `git_commits`，更新 `ccs-overview` 中的呼叫端傳入 `"$git_commits"`。

- [ ] **Step 3: 在 `_ccs_overview_git` 加 commit messages**

在每個專案的 section 末尾，加入：

```bash
if [ "$git_commits" -gt 0 ]; then
  printf -- '- **Recent Commits:**\n'
  git -C "$resolved" log --oneline --format="  - %h %ar — %s" -"$git_commits" 2>/dev/null
  printf '\n'
fi
```

- [ ] **Step 4: 修改 `_ccs_overview_git_json` 簽名和加 `recent_commits`**

更新簽名接收 `git_commits` 參數，更新 `_ccs_overview_git` 內的呼叫端。

```bash
local commits_json
commits_json=$(git -C "$resolved" log --format='{"hash":"%h","ago":"%ar","message":"%s"}' -"$git_commits" 2>/dev/null | jq -sc '.')
# 加入 result 的 jq 組裝
```

- [ ] **Step 5: 驗證**

```bash
ccs-overview --git              # 預設 3 個 commit
ccs-overview --git -n 1         # 1 個
ccs-overview --git -n 0         # 無 commit
ccs-overview --git --json       # JSON 有 recent_commits
ccs-overview -n 5 --git         # flag 順序反過來也要能用
```

- [ ] **Step 6: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(git): add recent commit messages to --git view"
```

---

## Task 6: `ccs-overview --files` — 跨 Session 檔案操作歷史

**Files:**
- Modify: `ccs-dashboard.sh` — 新增 `_ccs_overview_files`、`_ccs_overview_files_json`
- Modify: `ccs-dashboard.sh` — `ccs-overview` arg parser 加 `--files`

- [ ] **Step 1: 修改 `ccs-overview` arg parser 加 `--files` 和 `--all-ops`**

新 flag 加在 `*)` catch-all 之前。`--files` 設 `files_mode=true`，`--all-ops` 設 `all_ops=true`。

- [ ] **Step 2: 實作 `_ccs_overview_files`**

接收 `$mode` 參數（terminal/md/json），與 `_ccs_overview_git` 模式一致。Terminal 版暫時 fallback 到 md 輸出（不做 ANSI 版）。

遍歷 session_files 陣列，對每個 JSONL 用 jq 提取 tool_use（Read/Edit/Write），建立 per-file 統計：
- file path → { ops: {R: count, E: count, W: count}, sessions: [sid...], last_timestamp }

用 temp file 收集所有 session 的操作記錄，再 jq 彙整。
預設只顯示 E/W，`--all-ops` 含 R。
按 last_timestamp 排序，按專案分組輸出。

- [ ] **Step 3: 實作 `_ccs_overview_files_json`**

結構化 JSON 輸出。

- [ ] **Step 4: 驗證**

```bash
ccs-overview --files              # 預設 E/W only
ccs-overview --files --all-ops    # 含 Read
ccs-overview --files --json       # JSON
```

- [ ] **Step 5: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat: add --files view for cross-session file operations"
```

---

## Task 7: `ccs-overview --md` 提示 + Orchestrator Skill 更新

**Files:**
- Modify: `ccs-dashboard.sh` — `_ccs_overview_md` 末尾加 feature 提示
- Modify: `skills/ccs-orchestrator/SKILL.md` — Command Palette + 語意增強

- [ ] **Step 1: 修改 `_ccs_overview_md`**

在末尾加入 feature 計數提示：

```bash
local feature_count
feature_count=$(wc -l < "$(_ccs_data_dir)/features.jsonl" 2>/dev/null || echo 0)
if [ "$feature_count" -gt 0 ]; then
  printf '\n> %d features tracked — `ccs-feature` for details\n' "$feature_count"
fi
```

- [ ] **Step 2: 更新 Orchestrator Skill**

在 SKILL.md 的 Command Palette 新增：

| Command | Key | Action |
|---------|-----|--------|
| features | f | `ccs-feature --md` |
| feature N | f N | `ccs-feature --md <name>` |
| timeline N | tl N | `ccs-feature --md <name> --timeline` |
| files | fl | `ccs-overview --files --md` |
| tag | tag | `ccs-tag` |

新增 Routing Rules、Context-Aware Options 情境、語意增強說明。

- [ ] **Step 3: Commit**

```bash
git add ccs-dashboard.sh skills/ccs-orchestrator/SKILL.md
git commit -m "feat: add feature hint to overview + update orchestrator skill"
```

---

## Task 8: install.sh 清理 + README 更新

**Files:**
- Modify: `install.sh` — uninstall 加資料目錄清理
- Modify: `README.md` — 新增指令說明

- [ ] **Step 1: 修改 `install.sh` 的 `do_uninstall`**

在移除 bashrc 行之後，加入 `$XDG_DATA_HOME/ccs-dashboard` 清理邏輯。
`overrides.jsonl` 存在時需確認，否則直接刪。

- [ ] **Step 2: 更新 README**

新增 `ccs-feature`、`ccs-tag`、`ccs-overview --files`、`ccs-overview --git -n` 說明。

- [ ] **Step 3: 驗證 install.sh 語法**

```bash
bash -n install.sh
```

- [ ] **Step 4: Commit**

```bash
git add install.sh README.md
git commit -m "docs: update install.sh cleanup and README for Phase 3"
```

---

## Task 9: 端到端驗證

- [ ] **Step 1: 完整流程測試**

```bash
# 1. 確認聚類正常
ccs-feature --md

# 2. 手動標記
ccs-tag <session-prefix> <feature-id>
ccs-feature --md  # 確認變化

# 3. 詳細 view + 時間軸
ccs-feature --md <feature-id>
ccs-feature --md <feature-id> --timeline
ccs-feature --md <feature-id> -n 5

# 4. Git commits
ccs-overview --git -n 5

# 5. Files view
ccs-overview --files

# 6. Overview 有 feature 提示
ccs-overview --md | tail -5

# 7. JSON 輸出
ccs-feature --json | jq .
ccs-overview --files --json | jq .
```

- [ ] **Step 2: 清理 override 測試**

```bash
ccs-tag --clear <session-prefix>
ccs-tag --list  # 確認空
```

- [ ] **Step 3: 確認所有舊指令未被 break**

```bash
ccs-overview --md
ccs-overview --git
ccs-overview --json
ccs-overview --todos-only
ccs-status --md
ccs-pick --md 1
```

- [ ] **Step 4: Final commit（如有修正）+ push**
