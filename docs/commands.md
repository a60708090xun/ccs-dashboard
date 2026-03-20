# 指令詳細說明

回到 [README](../README.md)

## ccs-status (ccs)

一眼掌握所有 session 狀態，分三個區塊：
1. **Active Sessions** — 近 1 天內有活動的未封存 session
2. **Zombie Processes** — 被 suspend 的 claude process（吃 RAM）
3. **Stale Sessions** — 超過 1 天未動的未封存 session

```bash
ccs-status          # Terminal ANSI 輸出
ccs-status --md     # Markdown list 格式（預設，手機友善）
ccs-status --md --table   # Markdown table 格式（桌面寬螢幕）
```

Markdown 模式會產生帶編號的 session 列表，搭配 `ccs-pick` 互動瀏覽。

## ccs-pick N

展開 `ccs-status --md` 列表中第 N 個 session 的最近對話。

```bash
ccs-pick --md 3           # 顯示最後 3 組 prompt-response（預設）
ccs-pick --md -n 5 3      # 顯示最後 5 組
ccs-pick --md --full 3:9  # 完整展開第 3 個 session 的第 9 個 prompt response
```

使用流程：
1. `ccs-status --md` → 看到帶編號的 session 列表
2. `ccs-pick --md 3` → 展開 #3 的最近 3 組對話（response 截 10 行）
3. `ccs-pick --md --full 3:9` → 完整展開被截斷的 response

## ccs-sessions [hours]

列出指定時間內的所有 session（含已封存），按專案分組。

## ccs-active [days]

只列出未封存（open）的 session，適合快速找到還在進行中的工作。

## ccs-cleanup

找出 Stopped 狀態（`Tl`/`T`）的 claude process 並終止。
這些通常是 waveterm `/exit` 後被 SIGTSTP suspend 的殭屍，每個佔 190-500 MB RAM。

```bash
ccs-cleanup           # 互動確認後清理
ccs-cleanup --dry-run # 只列出，不殺
ccs-cleanup --force   # 跳過確認直接清理
```

## ccs-details [session-id-prefix]

互動式對話瀏覽器（Terminal），列出 session 中所有 user prompt，可上下選擇並展開完整回應。

自動過濾 meta/system messages（`isMeta`、`<local-command>`、`/exit`）。
中斷的 prompt 會在列表標記：⏸ = 使用者重送、🚫 = 完全沒回應。

```bash
ccs-details 4e716490      # 用 session ID 前綴指定
ccs-details               # 目前專案目錄的最近 session
ccs-details -a            # 搜尋所有專案
ccs-details --last        # 非互動：只顯示最後一組 prompt + response
```

互動模式按鍵：

```
↑/↓, j/k      導航
PgUp/PgDn      翻頁
g/G            跳到最舊/最新
Enter          展開完整 prompt + response（用 less 翻頁）
q, Esc         退出
```

中斷的 prompt 按 Enter 後會忠實呈現：
- 快速重送 → `(no response)`
- thinking 階段中斷 → `⚡ interrupted — agent was thinking`
- tool 執行中中斷 → `⚡ interrupted — agent was executing:` + 工具清單
- 回應到一半中斷 → 顯示部分回應 + `⚡ interrupted (response may be incomplete)`

## ccs-html

產生 standalone HTML dashboard 檔案（GitHub dark theme 風格）。

```bash
ccs-html              # 產生 dashboard.html
ccs-html --open       # 產生後用瀏覽器開啟
```

## ccs-handoff [project-dir]

為指定專案產生交接筆記（Markdown），自動填充：
- Open session 列表
- 過濾後的對話摘要（user + Claude 回應，跳過 meta messages）
- Git 狀態（branch、recent commits、uncommitted changes）
- 最近操作的檔案（Read/Edit/Write/Bash）
- TodoWrite 任務進度（如果有）
- Bootstrap prompt（可直接貼入新 session）

輸出位置：`~/docs/tmp/handoff/<date>-<topic>.md`

```bash
ccs-handoff                    # 目前目錄
ccs-handoff /path/to/project   # 指定專案
ccs-handoff -n 10              # 包含最近 10 組對話（預設 5）
ccs-handoff --no-prompt        # 不附 bootstrap prompt
```

## ccs-overview

跨 session 工作總覽，一次看完所有活躍 session 的狀態、最近對話、待辦事項、deadline context。

```bash
ccs-overview              # Terminal ANSI 輸出（預設，排除 subagent）
ccs-overview --md         # Markdown 輸出（給 Skill / Happy 網頁版）
ccs-overview --json       # JSON 輸出（給 Skill 做結構化推斷）
ccs-overview --git        # 跨專案 git 狀態
ccs-overview --todos-only # 只輸出跨 session 待辦彙整
ccs-overview --all        # 包含 subagent session
ccs-overview --git -n 5   # git 狀態 + 最近 5 個 commit
ccs-overview --files      # 跨 session 檔案操作（E/W）
ccs-overview --files --all-ops  # 含 Read 操作
```

## ccs-feature

以 feature/issue 為單位追蹤跨 session 進度。自動從 topic 中的 `GL#N` / `GH#N` 和 git branch 聚類 session。

```bash
ccs-feature              # Terminal ANSI 輸出
ccs-feature --md         # Markdown 輸出
ccs-feature --json       # JSON 輸出
ccs-feature gl65         # 展開指定 feature 詳細 view
ccs-feature gl65 --timeline  # 時間軸 view
ccs-feature gl65 -n 5    # 詳細 view 顯示 5 個 git commit
```

資料存放：`${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard/`

## ccs-tag

手動標記 session 歸屬到指定 feature，覆蓋自動聚類結果。

```bash
ccs-tag <session-prefix> <feature-id>           # 歸入
ccs-tag --exclude <session-prefix> <feature-id>  # 排除
ccs-tag --list                                    # 列出所有 override
ccs-tag --clear <session-prefix>                  # 移除該 session 所有 override
```

## ccs-recap

每日工作回顧，自動偵測上次工作日，收集所有專案的 session/todo/feature/git 數據。

```bash
ccs-recap              # 自動偵測上次工作日
ccs-recap 2d           # 最近 2 天
ccs-recap 2026-03-18   # 指定日期起算
ccs-recap --md         # Markdown 輸出
ccs-recap --json       # JSON 輸出（供 skill 層消費）
ccs-recap --project    # 僅當前專案
```

## ccs-resume-prompt [session-id-prefix]

從 JSONL session 自動產生精簡 bootstrap prompt（< 2000 tokens），設計用來貼入全新 session 無縫接手。

包含：project context、git 狀態、最近對話摘要、最近操作的檔案。

```bash
ccs-resume-prompt              # 目前目錄的最近 session
ccs-resume-prompt -a           # 所有專案的最近 session
ccs-resume-prompt 4e716490     # 指定 session
ccs-resume-prompt --copy       # 複製到剪貼簿
ccs-resume-prompt --stdout     # 純文字輸出（可 pipe）
ccs-resume-prompt -n 5         # 包含最近 5 組對話（預設 3）
```
