# 指令詳細說明

回到 [README](../README.md)

## ccs-status (ccs)

一眼掌握所有 session 狀態，分四個區塊：
1. **Active Sessions** — 近 1 天內有活動的未封存 session
2. **Crashed Sessions** — crash-interrupted session（由 `ccs-crash` 偵測邏輯判定）
3. **Zombie Processes** — 被 suspend 的 claude process（吃 RAM）
4. **Stale Sessions** — 超過 1 天未動的未封存 session

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

## ccs-crash

偵測被 crash 或非預期重開機中斷的 session，並提供清理功能。

`ccs-active` 會以紅色 💀 標記 crash session，底部顯示清理指引。

```bash
ccs-crash                      # Markdown 輸出，僅顯示 high confidence（預設）
ccs-crash --json               # JSON 輸出
ccs-crash --all                # 包含 low confidence + subagent sessions
ccs-crash --clean              # 互動式清理（逐一 archive/skip/quit）
ccs-crash --clean-all          # 一鍵 archive 所有 high confidence crash sessions
ccs-crash --reboot-window N    # Path 1 window（分鐘，預設 30）
ccs-crash --idle-window N      # Path 2 window（分鐘，預設 1440）
```

### 偵測路徑

| Path | 觸發條件 | Confidence | 類型 |
|------|----------|------------|------|
| Path 1 (reboot) | session mtime 在 boot 前 30 分鐘內，無 running process | high | `reboot` |
| Path 1 (reboot-idle) | session mtime 在 boot 之前（idle 狀態被 reboot 殺掉） | high | `reboot-idle` |
| Path 2 (non-reboot) | process 已死 + 最後回應無 text content | high | `non-reboot` |
| Path 2 (non-reboot-idle) | process 已死 + 最後回應有 text（閒置後中斷） | high | `non-reboot-idle` |
| Path 2 (hung) | process 在但 JSONL 超過 1 小時沒更新 | high | `hung` |

### Running process 偵測

判斷 session 是否仍在執行使用兩種方法：

1. **精確匹配**：`ps` 抓 `--resume <session-id>`（適用 `claude --resume` 啟動的 session）
2. **cwd 匹配**：比對 claude process 的工作目錄與 session 的 project 路徑（適用 Happy 啟動或 terminal 直接開的 session）。路徑使用正規化比對（`/._` 統一為 `-`）解決 Claude Code 路徑編碼歧義。

Hung detection 僅對精確匹配的 session 生效，cwd 匹配因無法確定 process 對應哪個 session，不做 hung 判斷。

### 清理功能

`--clean` 和 `--clean-all` 透過寫入 `last-prompt` marker 到 JSONL 來 archive crash session，清理後 `ccs-active` 不再顯示該 session。

```bash
# 互動式：逐一確認
$ ccs-crash --clean
[1/14] 60a75dec — ~(home)
  Topic: 分析一下目前我的 happy daemon 狀態
  Type:  high:reboot
  (a)rchive  (s)kip  (q)uit? a
  ✓ Archived

# 批次：全部 archive
$ ccs-crash --clean-all
Archiving 14 crashed sessions...
  ✓ 60a75dec
  ✓ 1266d974
  ...
Done: 14 sessions archived.
```

### Archived 判斷

`_ccs_is_archived()` 共用函式判斷 session 是否已結束：

1. JSONL 最後一行是 `/exit` 的 stdout event（`Goodbye!` 或 `See ya!`）
2. `last-prompt` marker 存在且之後無 `assistant` event

> **已知問題**：Claude Code 在 resume → `/exit` 時可能不寫 `last-prompt` marker。Check 1 處理此情況。

### 輸出範例

```
## ⚠️ Crash-Interrupted Sessions (boot: 2026-03-20 09:47)

### 🔴 b9acc81f — specman/cases — Exp-G5 分析
- **Confidence:** high (reboot)
- **最後活動：** 09:38（9m ago）
- **最後訊息：** 好
- **Git：** master (4 uncommitted files)
- **Resume：** `claude --resume b9acc81f-...`
- **Detail：** `ccs-session b9acc81f`

---
cleanup: `ccs-crash --clean` (interactive) | `ccs-crash --clean-all` (batch)
```

## ccs-checkpoint

輕量級進度快照，三欄式分類（Done / In Progress / Blocked）。用於早上 recap 或會議前彙報。

```bash
ccs-checkpoint                    # 上次 checkpoint 到現在（首次用今天 00:00）
ccs-checkpoint --since 9:00       # 今天 09:00 起
ccs-checkpoint --since yesterday  # 昨天 00:00 起
ccs-checkpoint --since "2h ago"   # 2 小時前起
ccs-checkpoint --md               # Markdown 條列式輸出
ccs-checkpoint --md --table       # Markdown 表格式輸出
ccs-checkpoint --project          # 只看當前目錄的專案
```

三欄分類邏輯：
- **Done** — 區間內已封存的 session
- **In Progress** — 區間內有活動、未封存的 session（展開 todos）
- **Blocked** — In Progress 中 inactive > 2h 或含 blocked/卡住 等 keyword

時間戳持久化：每次預設區間執行後記錄時間，下次自動接續。

## ccs-health

Session health detection — 偵測注意力退化信號。
掃描 active sessions，依三個指標評分並分級顯示。

```bash
# 全域掃描所有 active sessions
ccs-health
# Markdown 輸出
ccs-health --md
# JSON 輸出
ccs-health --json
# 指定 session（prefix 即可）
ccs-health <session-id-prefix>
```

三個偵測指標：
- **重複 tool call** — 同一檔案被 Read/Grep 多次
- **Session 持續時間** — session 開始到現在的時長
- **Prompt-response 輪數** — 對話來回次數

分級：🟢 green（正常）/ 🟡 yellow（注意）/ 🔴 red（退化）

整體等級取三項指標中最差的一項。

閾值預設值（可用環境變數覆蓋）：

```
CCS_HEALTH_DUP_YELLOW=3      # 重複 tool call 黃色閾值
CCS_HEALTH_DUP_RED=5        # 重複 tool call 紅色閾值
CCS_HEALTH_DURATION_YELLOW=2880  # 持續時間黃色閾值（分鐘）
CCS_HEALTH_DURATION_RED=4320     # 持續時間紅色閾值（分鐘）
CCS_HEALTH_ROUNDS_YELLOW=30     # 輪數黃色閾值
CCS_HEALTH_ROUNDS_RED=60        # 輪數紅色閾值
```

詳見 `ccs-health.sh`。

## ccs-dispatch

派工到新 Claude Code session。混合模式：預設 async（nohup detach），可選 sync（blocking）。

```bash
# Async（預設）— 立即回傳 job-id
ccs-dispatch --project ~/my-project \
  "fix lint warnings"

# Sync — blocking 等結果（適合短任務）
ccs-dispatch --sync --project ~/my-project \
  "list all TODO comments"

# 注入 git context
ccs-dispatch --context \
  --project ~/my-project \
  "complete pending TODOs"

# 自訂 timeout
ccs-dispatch --timeout 300 \
  --project ~/my-project \
  "run full test suite"
```

參數：

```
--sync         Blocking 等結果（預設 timeout 120s）
--async        預設模式（nohup detach，timeout 600s）
--context      注入目標專案 git 狀態
--timeout <s>  覆蓋預設 timeout
--project <d>  目標專案目錄（必填）
```

可配置環境變數：

```
CCS_DISPATCH_SYNC_TIMEOUT=120     # sync 預設 timeout
CCS_DISPATCH_TIMEOUT=600          # async 預設 timeout
CCS_DISPATCH_RESULT_TTL_DAYS=7    # 結果檔保留天數
CCS_DISPATCH_MAX_CONCURRENT_WARN=3  # 並行 job 警告閾值
```

結果存放：`${XDG_DATA_HOME:-~/.local/share}/ccs-dashboard/dispatch/`

## ccs-jobs

查看 dispatch 任務歷史與結果。

```bash
ccs-jobs              # 最近 20 筆
ccs-jobs --all        # 全部
ccs-jobs <job-id>     # 單筆詳細結果（顯示 .md）
```
