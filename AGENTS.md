# ccs-dashboard — Agent 共通規則

此檔案定義所有 AI agent（Claude Code、Gemini CLI 等）在本專案的共通行為準則。
各 agent 的專屬規則在各自的 MD 檔（`CLAUDE.md`、`GEMINI.md`）。

## 開發流程

主分支 `master` 禁止直接 commit（version bump 除外），所有開發使用 worktree。

一個 **Sprint** 是一個開發項目（解 issue 或做功能），依以下 Phase 推進：

```
Phase 0 發想: （主目錄）→ 可行 → 建 worktree
Phase 1 規劃: （worktree）→ design doc → 第一個 commit
Phase 2 實作: （worktree）→ 開發 + commit
Phase 3 收尾: （worktree）→ 整理 → review → merge → 清理
```

### Phase 3 收尾（必須按順序）

1. **Code review：** 依複雜度選擇方式，發現問題 → 修正 patch commit
2. **更新跨文件引用：** 依 `docs/sync-checklist.md` 逐項檢查，**這步完成前不得 push 或發 PR**
3. **整理 commit：** 細碎 commit 用 `git rebase` 整理成邏輯階段（review 修正一併整理）
4. **發 PR：** push branch → `gh pr create`，PR body 附 review + test report
5. **Merge：** `gh pr merge --rebase --delete-branch`（不要本地 merge + push）
6. **清理：** 刪除 worktree（`git worktree remove`）
7. **Version bump（如需 release）：** 見下方 Release 流程
8. **Release（如需 release）：** 見下方 Release 流程

## Release 流程

版號遵循 [SemVer](https://semver.org/)，agent 根據 commit 內容自行判斷 bump 級別：

- **major**：breaking change（使用者腳本可能壞掉）
- **minor**：新功能、新指令
- **patch**：bug fix、文件修正

### Release 步驟

**CRITICAL: 即使 PR 已獲准，在執行以下步驟前必須再次徵詢使用者明確授權 (如：「執行發佈」)。禁止 AI 自行決定 Push 時機。**

1. 更新 `CHANGELOG.md`（[Keep a Changelog](https://keepachangelog.com/) 格式）
2. Commit：`chore: bump version to vX.Y.Z`
3. Tag：`git tag vX.Y.Z`
4. Push：`git push origin master --tags`
5. Release：`gh release create vX.Y.Z --title "vX.Y.Z — <簡述>" --notes "<release notes>"`

> **Version bump 是唯一允許直接 commit 到 master 的例外。**
> 因為 bump 發生在 PR merge 之後、tag 之前，中間插入 branch + PR 沒有意義。

### Release Regression 處理

發現 regression 但使用者還沒拿到該版本時：

1. 刪除 release + tag（`gh release delete` + `gh api repos/.../git/refs/tags/... -X DELETE`）
2. 修復 → PR → merge
3. 重新跑 release 流程，版號不變

## 模組化架構

程式碼按功能拆為模組，`ccs-dashboard.sh` 是唯一入口。新增或修改指令前，先讀 `docs/adr/001-modular-source-split.md` 確認歸屬模組與 checklist。

## 內部文件規則

專案文件依「durable 與否」分兩落點：

**Durable dev-facing 架構文件 → committed `docs/internal/`（進版控）：**
- 跨函式才看得出的架構不變量、狀態檔生命週期、orchestration 設計等，對後續
  developer / agent 有長期參考價值者。
- 例：`docs/internal/architecture-invariants.md`、`docs/internal/state-file-lifecycle.md`。
- 這類文件是**蒸餾**產物（synthesized、對 code 逐條驗證後才寫），不是把 per-sprint
  草稿直接搬進版控。
- ⚠ 本 repo 為 **public**：commit 前必須脫敏——無個人 path、內網 hostname / IP、
  credential（per cross-repo-docs 紀律）。

**Ephemeral 開發產出 → `internal/`（已 gitignore），禁止 commit：**
- 交接文件（handoff）
- per-sprint 設計 spec（`*-design.md`）、實作計畫（`*-plan.md`）
- brainstorming / superpowers 產出
- per-sprint worklog 放 worktree `tmp/sprint/worklog.md`（隨 worktree 刪除閉合）

Phase 1 規劃時，per-sprint spec/plan 寫在 `internal/`（gitignore，不進 git）。某設計
成熟、對後續有 durable 價值時，再蒸餾成 committed `docs/internal/` 架構文件。
（`.gitignore` 用 `/internal/` anchor repo root，只 ignore 頂層 `internal/`，不影響
committed `docs/internal/`。）

## Worktree 與 Branch

- **目錄位置：** repo 內 `.worktrees/<name>`（已 gitignore，不進版控）
- **Branch prefix：** `feat/`（新功能）、`fix/`（修復）、`refactor/`（重構）、`docs/`（文件）

## MR/PR 產出物 provenance（本 repo 作為 `mr-review-artifacts` 消費者）

契約層（§0 欄位規則、§1 independent review report、§2 CIA、§3 description 與其他
comment）由個人 `mr-review-artifacts` skill 定義。該契約要求**每個消費 repo 自持
三件 repo-specific 事項**，本節即是——寫在這裡才對非-Claude executor（Gemini /
wingman worker）可達，放個人全域層等於未送達。

### CIA 觸發清單（§2）

diff 命中以下任一面 → 必跑 Change Impact Analysis 並貼為 PR comment，**merge 前完成**：

- **共用模組**：`ccs-core.sh`（所有指令共用的 session parse / 格式 helper）、
  `ccs_collect.py`（統一收集層，session-list 類指令的上游——ADR-002；
  `ccs-review` / `ccs-project` **不經過**它，兩者各自逐 JSONL 解析）、
  `ccs-dashboard.sh` 的 source 順序（唯一入口；模組增減的同步義務見
  `docs/sync-checklist.md`，本清單只管影響分析）。
- **住在 feature 模組裡的 cross-module helper**（最易被誤判為 leaf）：
  `ccs-review.sh` 的 `_ccs_session_stats` / `_ccs_tool_use_stats`（被 `ccs-project.sh`
  消費）、`ccs-health.sh` 的 `_ccs_health_badge_md` / `_ccs_health_events` /
  `_ccs_health_score`（被 `ccs-overview.sh` 消費）。
- **後端 / executor 分流點**：`ccs-dispatch.sh` 的 backend 選擇
  （`headless` ↔ `agentpager`）與 executor 分派（`claude` / `gemini` / `wingman`）。
- **task.yaml schema**（對外契約）：`_ccs_dispatch_gate_load_task` 的 jq 驗證。
  使用者的 task 檔與已分發的 `skills/ccs-dispatch-run` 共同依賴它，加一個必填欄位
  會讓既有 task.yaml 全部 validation 失敗（對應文件
  `skills/ccs-dispatch-run/references/task-yaml.md`）。
- **outbound chain**：agent-pager 通知路徑（outbound sender 解析、job 完成通知）、
  handoff 續鏈（`--chain`）。
- **部署面**：`install.sh`（modules array、`~/.bashrc` source line）、
  `skills/install.sh`（skill 連結的唯一實作處，且被個人 config 層的 sync 在**每次
  push 收尾**呼叫——改壞它等於讓所有 skill 對 agent 靜默消失）、`skills/` 下已分發
  的 skill。
- **上游 CLI 相容面**：`ccs-canary-versions.txt`（`ccs_collect.py` 讀取的 known-good
  claude CLI 版本清單）。注意風險方向：沒有 parsing 邏輯讀這份清單，誤列一筆的後果
  是**消音**「版本未驗證、偵測可能失準」那行警示，讓解析靜默失準。
- 未命中但自判有跨模組影響 → 可自主加跑（advisory 加分，不算違規）。

新增共用模組時同步維護本清單。

### CIA 第 3 欄變體軸（§2）

本 repo 有四條變體軸，填該欄時逐條比對，不適用者明寫「無」：

- **Provider**：Claude `[C]` ↔ Gemini `[G]` 的 session 收集與解析（ADR-002 duck-typing）
- **Executor**：`claude` / `gemini` / `wingman`（wingman 無 model 旗標、僅作
  provenance，且 FAIL 直接 escalate 不 retry；`backend=agentpager` 與
  `executor=wingman` 互斥，schema 層直接擋）
- **Backend**：`headless` ↔ `agentpager`。**兩個分流點行為不同，須分開比對**——
  別套用單一的「同步 / 非同步」標籤，那在兩邊都不成立：
  - **gate-run**（task.yaml 的 `.backend`）：兩者皆同步，agentpager 走前景阻塞
    spawn+wait（非 async monitor），且**不 fallback**——daemon 不在就記錯誤讓 gate
    對 ground truth FAIL，不降級。
  - **job spawn**（`CCS_DISPATCH_BACKEND`）：headless 預設 `nohup` 非同步
    （`--sync` 才同步）；agentpager async-only，且會在三種條件下 fallback 回 headless。
  - 共同點：agentpager 單 seat（key `local-<user>`，multi-worker 為 v2）。
- **語言層**：bash ↔ python 的邊界。主軸是 collector 的 11 欄 pipe 協定
  （ADR-002 格式定義）；另有三個 JSON-over-stdin 邊界（`ccs_resume.py`、
  `ccs-project-render.py`、`ccs-review-render.py`），動到時一併比對。

### §0 Channel 的啟動路徑

Channel 欄寫「工具 + 啟動路徑」粒度——只寫工具名分不出「遠端無人值守」與「桌前有人
盯著」，而那正是 audit 要的區分。

**precedence：prompt 給的值優先於下表。** launched session 的 system prompt 已由
agent-pager 的 `provenance_footer()` 注入**解好的 Channel 字串**（handler 在啟動時
權威知道 channel 與 slot）——收到就照抄，不要再自行 env 判定。下表是桌前直跑與注入
缺席時的 fallback。

**判定順序（先判 channel，再判 launched）**——web launch 會同時注入
`AGENT_PAGER_SESSION_TREE` 與 `AGENT_PAGER_CHANNEL=web`，反序會把 web 誤標成 Path B：

1. `AGENT_PAGER_CHANNEL=web` → `agent-pager Path C (web slot <N>)`
   （slot 取 `AGENT_PAGER_BOT_SLOT` 並剝掉 `web-` 前綴）
2. `AGENT_PAGER_CHANNEL=local` → `agent-pager local channel`
   （此路徑**不注入** `AGENT_PAGER_BOT_SLOT`，別去取）
3. 否則 `AGENT_PAGER_SESSION_TREE` 有值 → `agent-pager Path B (telegram slot <N>)`
   （slot 取 `AGENT_PAGER_BOT_SLOT`，此路徑下為數字）
4. 皆不成立（桌前直跑）→ `inline (desktop Path A)`

字樣與判定順序對齊 agent-pager repo 的同名 section（該 repo 是 Path A/B/C 分類法的
SoT）。另有一條本 repo 專屬：由 `ccs-dispatch` 派出的 worker 所產出的內容，stamp
**worker 自身**的 model，Channel 寫該 worker 的 backend（`headless` / `agentpager`）。

判定信號 best-effort：env 會被繼承（背景 monitor fork、dispatched worker 繼承
parent 的 session 標記），讀不到或失真時以實際執行者為準，或省略路徑後綴不猜。

## GitHub Issue 語言規則

- **標題：** 英文
- **內容與 comment：** 繁體中文（台灣用語），與 global 語言規範一致
- 程式碼區塊、變數名稱、技術術語維持英文
