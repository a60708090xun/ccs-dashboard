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
2. **更新跨文件引用：** 確認 README、install.sh、SKILL.md 等已同步
3. **Code review：** 依複雜度選擇方式，發現問題 → 修正 patch commit
4. **Plan 歸檔：** Plan/spec 文件移至 `docs/archived/`
5. **Merge：** fast-forward merge 到 master
6. **清理：** 刪除 branch + worktree

### Worktree 與 Branch

- **目錄位置：** 專案同層級，如 `<project-root>-<name>`
- **Branch prefix：** `feat/`（新功能）、`fix/`（修復）、`refactor/`（重構）、`docs/`（文件）

## 模組化架構（ADR-001）

程式碼按功能拆為模組，`ccs-dashboard.sh` 是唯一入口。

**新增指令歸屬：**
- session 瀏覽/互動 → `ccs-viewer.sh`
- session 交接/銜接 → `ccs-handoff.sh`
- 跨 session 彙總 → `ccs-overview.sh`
- feature 追蹤 → `ccs-feature.sh`
- 運維/診斷/報告 → `ccs-ops.sh`
- 任務派遣 → `ccs-dispatch.sh`
- health 評分 → `ccs-health.sh`
- 不屬於以上且 > 200 行 → 建新模組

**共用 helper 規則：** 被 2+ 模組使用 → 放 `ccs-core.sh`，單一模組專用 → 留在該模組。

**新增模組 checklist：**
1. 建立 `ccs-<name>.sh`，header 加 `Sourced by ccs-dashboard.sh`
2. 在 `ccs-dashboard.sh` 加 source（注意依賴順序）
3. 在 `install.sh` 的 `modules` 陣列加入檔名
4. 更新 README 檔案結構

詳見 `docs/adr/001-modular-source-split.md`。

## GitHub Issue 語言規則

- **標題：** 英文
- **內容與 comment：** 繁體中文（台灣用語），與 global 語言規範一致
- 程式碼區塊、變數名稱、技術術語維持英文
