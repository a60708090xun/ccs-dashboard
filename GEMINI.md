# ccs-dashboard — Gemini CLI 規則

> 請先讀 `AGENTS.md` 載入共通規則（開發流程、release、模組架構等）。

## 硬性阻斷規則 (Hard Gates)

1. **禁止越權 Push**：即使 PR 已通過，在執行 `git push origin master` 前必須獨立詢問：「`[確認詢問] 我已準備好 Master 同步內容，是否核准 Push？`」
2. **禁止自動 Release**：在執行 `gh release create` 前必須獲得明確的發佈指令。

<!-- 目前無 Gemini-specific 規則，未來有需要時在此擴充。 -->
