# ADR 003: Code CLI Sessions - Unified Multi-Provider Architecture

- **日期：** 2026-04-09
- **狀態：** accepted
- **關聯：** 引入 Gemini 支援

## Context

`ccs-dashboard` 原先是專為 Claude Code 設計的任務指揮中心，高度依賴解析 `~/.claude/projects/` 底下的 JSONL 檔案。隨著 Gemini CLI 等其他強大工具的出現，我們希望讓 `ccs-dashboard` 也能管理 Gemini 的 sessions，實現真正的 "Mission Control" 體驗。

然而，Gemini CLI 的底層儲存機制與 Claude Code 有顯著差異：
1. **路徑不同**：Gemini 儲存於 `~/.gemini/tmp/<project-name>/chats/`（以及 `history` 目錄）。
2. **格式不同**：Gemini 使用單一的 JSON 檔案（而非 JSONL）。

若要同時支援兩者，繼續完全依賴 Bash + `jq` 來解析複雜且格式不同的 JSON 會使 `ccs-core.sh` 變得難以維護。

## Decision

1. **名稱重定義**：保留 `ccs-*` 命名，將其縮寫重新定義為 "**C**ode **C**LI **S**essions"，淡化特定供應商的色彩。
2. **統一混合視圖 (Unified View)**：
   - 不區分「Claude 模式」或「Gemini 模式」，而是將所有 Session 統一依照時間或狀態排序混排呈現。
   - 在終端機輸出中新增獨立的 `PROV` 欄位（顯示 `[C]` 或 `[G]`）。
   - 在 Markdown 輸出中使用明確的標籤如 `[Claude]` 或 `[Gemini]`。
3. **引入 Python 收集層 (Polyglot Wrapper)**：
   - 建立 `internal/ccs_collect.py` 負責統一掃描與解析 Claude 的 JSONL 與 Gemini 的 JSON 檔案。
   - 該腳本負責萃取共用屬性（`provider`, `project`, `session_id`, `last_active`, `topic`）並計算狀態（status, color）。
   - 腳本透過 `stdout` 輸出 Tab-Separated Values (TSV) 格式。
4. **Bash 層介面合約**：
   - 修改 `ccs-core.sh` 中的 `_ccs_collect_sessions`，讓它呼叫 `python3 internal/ccs_collect.py` 並利用輸出的 TSV 直接進行後續的 `sort` 和顯示。

## Consequences

**好處：**
- 對現有使用者的操作習慣與指令（如 `ccs-status`, `ccs-active`）零衝擊，無痛引入 Gemini。
- Python 處理 JSON 遠比 Bash 穩健，未來的擴充性（如加入更多 AI 工具）會大幅提高。
- 將資料收集（Data Collection）與資料呈現（Presentation）解耦。

**代價：**
- 引入了 Python 3 作為執行環境的依賴（雖然多數 Linux 系統皆已內建）。
- 原本純 Bash 的架構不再純粹，必須維護一段 Python 程式碼。
- 深度依賴 `jq` 解析 JSONL 內容的進階功能（如 `ccs-details`, `ccs-handoff`）需要分階段逐步支援 Gemini 或提供 Fallback 機制。