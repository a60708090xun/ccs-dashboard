# 架構與檔案結構

回到 [README](../README.md)

程式碼按功能拆為模組，`ccs-dashboard.sh` 是唯一入口（source 所有模組）。新增或修改指令前，先讀 [adr/001-modular-source-split.md](adr/001-modular-source-split.md) 確認歸屬模組與 checklist。

## 檔案結構

```
ccs-core.sh           # 共用 helper + 基礎指令 (sessions/active/cleanup)
ccs-dashboard.sh      # 入口 — source 所有模組 + ccs-status, ccs-pick
ccs-health.sh         # Session health 評分
ccs-failure-triage.sh # Model-failure 快速分類
ccs-viewer.sh         # ccs-html, ccs-details
ccs-handoff.sh        # ccs-handoff, ccs-resume-prompt
ccs-overview.sh       # ccs-overview + render helpers
ccs-feature.sh        # Feature clustering + ccs-feature, ccs-tag
ccs-ops.sh            # ccs-crash, ccs-recap, ccs-checkpoint
ccs-dispatch.sh       # ccs-dispatch, ccs-jobs
ccs-review.sh         # ccs-review — session 回顧報告
ccs-project.sh        # ccs-project — 專案層級洞察報告
install.sh            # 安裝腳本（依賴檢查 + bashrc + skill symlink）
templates/            # Jinja2 HTML 模板（ccs-review、ccs-project 用）
skills/               # Claude Code skill — 主要介面
docs/                 # CLI 指令參考 + 歸檔設計文件
```

## 架構決策

- [adr/001-modular-source-split.md](adr/001-modular-source-split.md) — 模組化拆分（單一入口 source 多模組）
- [adr/002-unified-multi-provider-architecture.md](adr/002-unified-multi-provider-architecture.md) — 統一多 Provider 架構
