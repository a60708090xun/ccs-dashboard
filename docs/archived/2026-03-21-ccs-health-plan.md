# ccs-health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 `ccs-health` 指令，偵測 session 注意力退化信號，分級顯示健康狀態，並整合進現有 `ccs-status` / `ccs-overview`。

**Architecture:** 獨立 `ccs-health.sh` 模組，三層架構（資料層萃取 event stream → 計算層分級 → 展示層輸出）。被 `ccs-dashboard.sh` source，共用 `ccs-core.sh` 基礎設施。輸出標準化 JSON，介面通用化不綁定特定 agent。

**Tech Stack:** Bash, jq

**Spec:** `internal/2026-03-21-ccs-health-design.md`

---

## File Structure

- **Create:** `ccs-health.sh` — 全部 health 相關函式
- **Modify:** `ccs-dashboard.sh:21` — 加 source ccs-health.sh
- **Modify:** `ccs-core.sh:114` — _ccs_session_row 加 health 欄位
- **Modify:** `ccs-dashboard.sh:1524-1704` — _ccs_overview_md 加 health badge
- **Modify:** `ccs-dashboard.sh:1706-1837` — _ccs_overview_json 加 health 欄位
- **Modify:** `install.sh:100-117` — 加 ccs-health.sh 檢查

**注意：** Session 列舉使用現有的 `find` + `_ccs_session_row` pattern（見 ccs-core.sh:339-341），不需要新增 `_ccs_active_sessions()` 函式。
- **Modify:** `skills/ccs-orchestrator/SKILL.md:29-75` — 加 health 指令
- **Create:** `tests/test-health.sh` — health 功能測試

---

### Task 1: 建立 ccs-health.sh 骨架 + 環境變數

**Files:**
- Create: `ccs-health.sh`

- [ ] **Step 1: 建立檔案骨架**

```bash
#!/usr/bin/env bash
# ccs-health.sh — Session health detection
# Sourced by ccs-dashboard.sh

# === Thresholds (env var overridable) ===
CCS_HEALTH_DUP_YELLOW="${CCS_HEALTH_DUP_YELLOW:-3}"
CCS_HEALTH_DUP_RED="${CCS_HEALTH_DUP_RED:-5}"
CCS_HEALTH_DURATION_YELLOW="${CCS_HEALTH_DURATION_YELLOW:-120}"
CCS_HEALTH_DURATION_RED="${CCS_HEALTH_DURATION_RED:-240}"
CCS_HEALTH_ROUNDS_YELLOW="${CCS_HEALTH_ROUNDS_YELLOW:-30}"
CCS_HEALTH_ROUNDS_RED="${CCS_HEALTH_ROUNDS_RED:-60}"
```

- [ ] **Step 2: 確認 bash -n 語法檢查通過**

Run: `bash -n ccs-health.sh`
Expected: 無輸出（成功）

- [ ] **Step 3: Commit**

```bash
git add ccs-health.sh
git commit -m "feat(health): add ccs-health.sh skeleton with configurable thresholds (GH#17)"
```

---

### Task 2: 資料層 — _ccs_health_events()

**Files:**
- Modify: `ccs-health.sh`
- Create: `tests/test-health.sh`

- [ ] **Step 1: 建立測試檔案，寫 _ccs_health_events 的測試**

建立 `tests/test-health.sh`，建立測試用 JSONL fixture，測試 _ccs_health_events 輸出包含正確的 prompt_count、tool_reads 計數、first_ts、last_ts。

測試用 fixture：手動建立一個小型 JSONL 檔案，包含：
- 3 個 user prompt（type: user, content: string, 非 isMeta）
- 1 個 meta message（isMeta: true，不應計入）
- assistant 的 tool_use：Read 同一檔案 3 次、Read 另一檔案 1 次、Grep 同一 pattern 2 次
- 有 timestamp 的紀錄

驗證輸出的 JSON 符合 event stream 格式。

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test-health.sh`
Expected: FAIL（_ccs_health_events 未定義）

- [ ] **Step 3: 實作 _ccs_health_events()**

在 `ccs-health.sh` 中實作。接收 `$1` = JSONL 路徑，用 `jq --slurp` + `reduce` 一次萃取：
- `session_id`：從 `$1` 檔名取前 8 字元
- `first_ts` / `last_ts`：第一筆和最後一筆含 `.timestamp` 的紀錄
- `prompt_count`：`type == "user"` 且 content 為 string 且非 isMeta
- `tool_reads`：assistant tool_use 中 name == "Read" 的 file_path 計數
- `tool_greps`：assistant tool_use 中 name == "Grep" 的 pattern 計數

```bash
_ccs_health_events() {
  local f="$1"
  local sid
  sid=$(basename "$f" .jsonl | cut -c1-8)
  jq --slurp --arg sid "$sid" '
    # ... reduce logic ...
  ' "$f"
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test-health.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-health.sh tests/test-health.sh
git commit -m "feat(health): implement _ccs_health_events() with test (GH#17)"
```

---

### Task 3: 計算層 — _ccs_health_score()

**Files:**
- Modify: `ccs-health.sh`
- Modify: `tests/test-health.sh`

- [ ] **Step 1: 寫 _ccs_health_score 的測試**

在 `tests/test-health.sh` 中新增測試案例：
- Case 1: 全 green（low values）
- Case 2: yellow（duration 超標）
- Case 3: red（dup_tool 超標）
- Case 4: 複合情境（多指標不同級別，overall 取最嚴重）

每個 case 用 echo pipe 方式傳入 event stream JSON，驗證輸出的 overall 和各 indicator level。

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test-health.sh`
Expected: 新測試 FAIL

- [ ] **Step 3: 實作 _ccs_health_score()**

透過 stdin 接收 event stream JSON，用 jq 計算分級：

```bash
_ccs_health_score() {
  jq --argjson dup_y "$CCS_HEALTH_DUP_YELLOW" \
     --argjson dup_r "$CCS_HEALTH_DUP_RED" \
     --argjson dur_y "$CCS_HEALTH_DURATION_YELLOW" \
     --argjson dur_r "$CCS_HEALTH_DURATION_RED" \
     --argjson rnd_y "$CCS_HEALTH_ROUNDS_YELLOW" \
     --argjson rnd_r "$CCS_HEALTH_ROUNDS_RED" '
    # ... scoring logic ...
  '
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test-health.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-health.sh tests/test-health.sh
git commit -m "feat(health): implement _ccs_health_score() with tests (GH#17)"
```

---

### Task 4: 便利函式 — _ccs_health_badge / _ccs_health_badge_md

**Files:**
- Modify: `ccs-health.sh`
- Modify: `tests/test-health.sh`

- [ ] **Step 1: 寫 badge 函式測試**

測試 `_ccs_health_badge` 對 green/yellow/red session 輸出正確符號（`●`/`◐`/`○`）。
測試 `_ccs_health_badge_md` 輸出正確 emoji（🟢/🟡/🔴）。

使用 Task 2 的 fixture 或建立新 fixture。

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test-health.sh`
Expected: 新測試 FAIL

- [ ] **Step 3: 實作 badge 函式**

```bash
_ccs_health_badge() {
  local f="$1"
  local level
  level=$(_ccs_health_events "$f" \
    | _ccs_health_score \
    | jq -r '.overall')
  case "$level" in
    green)  printf '\033[32m●\033[0m';;
    yellow) printf '\033[33m◐\033[0m';;
    red)    printf '\033[31m○\033[0m';;
    *)      printf '?';;
  esac
}

_ccs_health_badge_md() {
  local f="$1"
  local level
  level=$(_ccs_health_events "$f" \
    | _ccs_health_score \
    | jq -r '.overall')
  case "$level" in
    green)  echo '🟢';;
    yellow) echo '🟡';;
    red)    echo '🔴';;
    *)      echo '⚪';;
  esac
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test-health.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-health.sh tests/test-health.sh
git commit -m "feat(health): add badge helper functions (GH#17)"
```

---

### Task 5: 展示層 — ccs-health 指令

**Files:**
- Modify: `ccs-health.sh`
- Modify: `tests/test-health.sh`

- [ ] **Step 1: 寫 ccs-health 指令的整合測試**

測試：
- `ccs-health --json` 輸出有效 JSON array
- `ccs-health <sid-prefix> --json` 輸出單一 session
- `ccs-health --md` 輸出包含 `## Session Health Report`

需要使用測試用 session 目錄（模擬 `~/.claude/projects/` 結構）。

- [ ] **Step 2: 跑測試確認失敗**

Run: `bash tests/test-health.sh`
Expected: 新測試 FAIL

- [ ] **Step 3: 實作 ccs-health 指令**

解析參數（session-id-prefix, --md, --json），列舉 active sessions，對每個 session 跑 `_ccs_health_events | _ccs_health_score`，依嚴重度排序，輸出三種格式。

展示層呼叫 `_ccs_topic_from_jsonl()` 和 `_ccs_friendly_project_name()` 取得 topic 和 project name。

- [ ] **Step 4: 跑測試確認通過**

Run: `bash tests/test-health.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ccs-health.sh tests/test-health.sh
git commit -m "feat(health): implement ccs-health command with terminal/md/json output (GH#17)"
```

---

### Task 6: 整合 — ccs-dashboard.sh source + ccs-status

**Files:**
- Modify: `ccs-dashboard.sh:21` — 加 source
- Modify: `ccs-core.sh:114` — _ccs_session_row 加 health 欄位

- [ ] **Step 1: 在 ccs-dashboard.sh 加 source**

在 line 21（`source ccs-core.sh` 之後）加：

```bash
source "${BASH_SOURCE[0]%/*}/ccs-health.sh"
```

- [ ] **Step 2: 修改 _ccs_session_row 加 health badge**

在 `ccs-core.sh` 的 `_ccs_session_row` 函式中，計算 health badge 並附加到輸出的 tab-separated 欄位尾端。

注意：只對 active/recent/idle 狀態的 session 計算 health（archived 和 stale 不需要）。

- [ ] **Step 3: 手動驗證 ccs-status 輸出**

Run: `source ccs-dashboard.sh && ccs-status`
Expected: 每個 active session 行尾有 health badge 符號（ccs-dashboard.sh 已 source ccs-health.sh）

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh ccs-core.sh
git commit -m "feat(health): integrate health badge into ccs-status (GH#17)"
```

---

### Task 7: 整合 — ccs-overview

**Files:**
- Modify: `ccs-dashboard.sh:1524-1704` — _ccs_overview_md
- Modify: `ccs-dashboard.sh:1706-1850` — _ccs_overview_json

- [ ] **Step 1: 修改 _ccs_overview_md**

在 session 標題旁附 health emoji badge（🟢/🟡/🔴）。
呼叫 `_ccs_health_badge_md "$f"` 取得 badge。

- [ ] **Step 2: 修改 _ccs_overview_json**

在每個 session JSON 物件中加 `health` 欄位。
呼叫 `_ccs_health_events "$f" | _ccs_health_score` 取得完整 health JSON。

- [ ] **Step 3: 手動驗證**

Run: `ccs-overview --md` 和 `ccs-overview --json`
Expected: md 有 emoji badge，json 有 health 欄位

- [ ] **Step 4: Commit**

```bash
git add ccs-dashboard.sh
git commit -m "feat(health): integrate health into ccs-overview md/json (GH#17)"
```

---

### Task 8: install.sh 更新

**Files:**
- Modify: `install.sh:100-117`

- [ ] **Step 1: 加 ccs-health.sh 檔案存在檢查**

在 install.sh 的檔案檢查區段（line 100-109 附近），加入：

```bash
if [ ! -f "${SCRIPT_DIR}/ccs-health.sh" ]; then
  fail "ccs-health.sh not found in ${SCRIPT_DIR}"
  exit 1
fi
```

- [ ] **Step 2: 加入語法檢查**

在 syntax check（line 111-117 附近），加入 `ccs-health.sh`：

```bash
if bash -n "${SCRIPT_DIR}/ccs-core.sh" \
   && bash -n "${SCRIPT_DIR}/ccs-health.sh" \
   && bash -n "${SCRIPT_DIR}/ccs-dashboard.sh"; then
```

- [ ] **Step 3: 跑 install.sh 驗證**

Run: `bash install.sh --check`（或 dry-run 模式）
Expected: 通過所有檢查

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "chore(install): add ccs-health.sh to install checks (GH#17)"
```

---

### Task 9: ccs-orchestrator Skill 更新

**Files:**
- Modify: `skills/ccs-orchestrator/SKILL.md:29-75`

- [ ] **Step 1: 加 health 指令到 Command Palette**

在指令表加入：

| health | h | 顯示 session health report |

- [ ] **Step 2: 加 routing rule**

加入 health 相關的路由規則，讓使用者輸入「健康」「health」「退化」等關鍵字時路由到 `ccs-health --md`。

- [ ] **Step 3: 更新 context-aware options 邏輯**

在 overview 結果有 yellow/red session 時，options 加入：
- 查看 session health 詳情
- 為 red session 生成 resume prompt（導向既有的 `ccs-resume-prompt`，不是自動生成）

- [ ] **Step 4: Commit**

```bash
git add skills/ccs-orchestrator/SKILL.md
git commit -m "feat(orchestrator): add health command to skill palette (GH#17)"
```

---

### Task 10: 最終驗證 + README

**Files:**
- Modify: `README.md` — 加 ccs-health 說明

- [ ] **Step 1: 全部測試通過**

Run: `bash tests/test-health.sh`
Expected: 全部 PASS

- [ ] **Step 2: bash -n 全部檔案**

Run: `bash -n ccs-core.sh && bash -n ccs-health.sh && bash -n ccs-dashboard.sh`
Expected: 無錯誤

- [ ] **Step 3: 更新 README.md**

在指令列表加入 `ccs-health` 說明。

- [ ] **Step 4: 更新 docs/commands.md（如果有）**

檢查是否有 commands.md，有的話同步更新。

- [ ] **Step 5: Commit**

```bash
git add README.md docs/commands.md
git commit -m "docs: add ccs-health to README and commands (GH#17)"
```
