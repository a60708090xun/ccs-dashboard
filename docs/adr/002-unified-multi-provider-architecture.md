# ADR-002: Unified Multi-Provider Architecture (Code CLI Sessions)

* **Status**: Accepted
* **Date**: 2026-04-09

## Context

`ccs-dashboard` 原先是專為 Claude Code 設計的任務指揮中心，高度依賴解析 `~/.claude/projects/` 底下的 JSONL 檔案。隨著 Gemini CLI 等其他工具的出現，我們面臨以下挑戰：
1. **多樣化的存儲機制**：不同 Provider 的檔案格式（JSONL vs JSON Array/Object）與目錄結構差異大。
2. **維護與一致性**：Topic 提取、狀態判定等邏輯散落在多個 Bash 模組中，難以同步。
3. **效能瓶頸**：純 Bash 處理數千個檔案時，頻繁啟動 `jq` 造成明顯延遲。

## Decision

1. **名稱與概念重定義**：
   - 將 `ccs-*` 縮寫重新定義為 "**C**ode **C**LI **S**essions"，淡化供應商色彩，轉向通用的 Mission Control 平台。
2. **統一混合視圖 (Unified View)**：
   - 所有 Provider 的 Session 統一混排，新增 `PROV` 欄位（`[C]` / `[G]`）供識別。
3. **引入 Python 收集層 (Polyglot Wrapper)**：
   - 建立 `internal/ccs_collect.py` 負責統一掃描與解析。
   - 採用 **Duck-typing 欄位提取**：定義統一的 session 欄位集，透明化原始資料結構。
4. **管道化通訊協定 (The Protocol)**：
   - 腳本透過 `stdout` 輸出 Pipe 分隔格式 (`|`)。
   - **格式定義**：`PROV|PROJECT|AGO_MINS|STATUS|COLOR|DISPLAY_PROJ|SID|AGO_STR|TOPIC|BADGE|FILEPATH`
   - 這讓 Bash 層能以極低開銷 (`while read`) 進行過濾與呈現。

## Consequences

* **優點**：
    * **極佳的擴充性**：支援新 Provider 僅需修改 Python collector，下游指令無需更動。
    * **邏輯集中**：解決了 Topic 提取與狀態判斷不一致的問題。
    * **效能提升**：利用 Python 批次處理，顯著加快看板載入速度。
* **缺點**：
    * 增加了對 Python 3 執行環境的依賴。
    * 深度解析功能（如 `ccs-details`）需針對不同格式提供專屬處理邏輯。
