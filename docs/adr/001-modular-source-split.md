# ADR-001: 拆分 ccs-dashboard.sh 為模組化 source files

- **日期：** 2026-03-23
- **狀態：** accepted
- **關聯：** GH#15

## Context

`ccs-dashboard.sh` 成長至 4687 行，
包含 7 個功能群組（status、viewer、handoff、
overview、feature、crash/recap/checkpoint、dispatch）。

單一檔案造成三個問題：

1. **維護困難：** 定位函式需搜尋整份檔案
2. **Review 成本高：** 改一個指令要看整個 diff
3. **AI context 浪費：** Claude Code 讀取時
   載入大量無關程式碼

## Decision

將 monolith 拆為以下模組結構：

```
ccs-core.sh      — 共用 helper + 基礎指令
ccs-dashboard.sh — 入口 + ccs-status, ccs-pick
ccs-viewer.sh    — ccs-html, ccs-details
ccs-handoff.sh   — ccs-handoff, ccs-resume-prompt
ccs-overview.sh  — ccs-overview + render helpers
ccs-feature.sh   — feature clustering + ccs-tag
ccs-ops.sh       — ccs-crash, ccs-recap, ccs-checkpoint
ccs-health.sh    — session health 評分
ccs-dispatch.sh  — ccs-dispatch, ccs-jobs
ccs-review.sh    — ccs-review
ccs-project.sh   — ccs-project
```

設計原則：

- **單一入口：** `.bashrc` 只 source
  `ccs-dashboard.sh`，由它 source 其他模組
- **依賴方向：** 所有模組依賴 `ccs-core.sh`，
  不互相依賴（除 overview → feature/ops
  的 session data 共用）
- **共用 helper 標準：** 被 2+ 模組使用的
  helper 放 `ccs-core.sh`
- **Source 順序：** core → health → viewer →
  handoff → overview → feature → ops → dispatch

## Consequences

**好處：**
- 每個模組 400-1300 行，易於維護
- PR review 只需看相關模組
- AI agent 可針對性讀取單一模組
- `bash -n` 可獨立驗證各模組語法

**代價：**
- 新增指令需判斷歸屬模組
- install.sh 需維護模組清單
- 跨模組 helper 搬遷需注意依賴

## 新增功能的歸屬判斷

```
新指令的主題是...
├── session 瀏覽/互動 → ccs-viewer.sh
├── session 交接/銜接 → ccs-handoff.sh
├── 跨 session 彙總   → ccs-overview.sh
├── feature 追蹤      → ccs-feature.sh
├── 運維/診斷/報告    → ccs-ops.sh
├── 任務派遣         → ccs-dispatch.sh
├── health 評分      → ccs-health.sh
└── 不屬於以上 → 考慮建新模組
```

建新模組的條件：
- 功能群組預計 > 200 行
- 與現有模組無明確歸屬關係
- 有獨立的 domain（不只是單一 helper）
