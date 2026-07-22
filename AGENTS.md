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

## GitHub Issue 語言規則

- **標題：** 英文
- **內容與 comment：** 繁體中文（台灣用語），與 global 語言規範一致
- 程式碼區塊、變數名稱、技術術語維持英文
