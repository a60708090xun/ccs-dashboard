# Cross-file Sync Checklist

Phase 3 收尾時，確認以下檔案的對應欄位已同步。

## 指令清單

新增或移除指令時，以下檔案都要更新：

- `README.md` — CLI commands 表格
- `docs/README.zh-TW.md` — 中文版指令表格
- `install.sh` — 安裝完成後的指令列表
- `skills/ccs-orchestrator/SKILL.md` — Command Palette
- `docs/commands.md` — 詳細用法與範例

## 狀態圖示

修改 session 狀態分類時：

- `README.md` — Status indicators section
- `docs/README.zh-TW.md` — 狀態圖示 section
- `docs/commands.md` — ccs-status 說明

## 模組檔案

新增或移除 `.sh` 模組時：

- `README.md` — File structure section
- `docs/README.zh-TW.md` — 檔案結構 section
- `install.sh` — modules array (line ~101)
- `ccs-dashboard.sh` — source 順序
