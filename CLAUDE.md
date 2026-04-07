# ccs-dashboard 專案規則

## 開發流程

主分支 `master` 禁止直接 commit，所有開發使用 worktree。

一個 **Sprint** 是一個開發項目（解 issue 或做功能），依以下 Phase 推進：

```
Phase 0 發想: （主目錄）→ 可行 → 建 worktree
Phase 1 規劃: （worktree）→ design doc → 第一個 commit
Phase 2 實作: （worktree）→ 開發 + commit
Phase 3 收尾: （worktree）→ 整理 → review → merge → 清理
```

### Phase 3 收尾（必須按順序）

1. **整理 commit：** 細碎 commit 用 `git rebase` 整理成邏輯階段
2. **Code review：** 依複雜度選擇方式，發現問題 → 修正 patch commit
3. **更新跨文件引用：** 依 `docs/sync-checklist.md` 逐項檢查，**這步完成前不得 push 或發 PR**
4. **發 PR：** push branch → `gh pr create`，PR body 附 review + test report
5. **Merge：** `gh pr merge --rebase --delete-branch`（不要本地 merge + push）
6. **清理：** 刪除 worktree（`git worktree remove`）

### 內部文件規則

以下文件放 `internal/`（已 gitignore），**禁止 commit 進 repo**：
- 交接文件（handoff）
- 設計 spec（`*-design.md`）
- 實作計畫（`*-plan.md`）
- brainstorming / superpowers 產出

Phase 1 規劃時，spec/plan 寫在 `internal/` 或 worktree 的 `internal/`，不加入 git。

### Worktree 與 Branch

- **目錄位置：** 專案同層級，如 `<project-root>-<name>`
- **Branch prefix：** `feat/`（新功能）、`fix/`（修復）、`refactor/`（重構）、`docs/`（文件）

## 模組化架構

程式碼按功能拆為模組，`ccs-dashboard.sh` 是唯一入口。新增或修改指令前，先讀 `docs/adr/001-modular-source-split.md` 確認歸屬模組與 checklist。

## GitHub Issue 語言規則

- **標題：** 英文
- **內容與 comment：** 繁體中文（台灣用語），與 global 語言規範一致
- 程式碼區塊、變數名稱、技術術語維持英文
