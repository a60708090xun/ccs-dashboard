---
name: ccs-dispatch-run
description: Review-gate 派工協定 — 把任務派給獨立 worker CLI，以 machine-checkable acceptance criteria 做零 LLM 現實驗收（不信 worker 自述）。Use when delegating a well-specified coding task that needs reality-based acceptance, or when chaining gated tasks. Not for interactive/exploratory work (use ccs-dispatch) or in-context subagents. Keywords: dispatch-run, review gate, task.yaml, acceptance criteria, verify.cmd, gated chain, evidence.
---

# ccs-dispatch-run 呼叫協定

把「派工 → 以現實驗收 → 失敗帶事實摘要重派一次」包成一個前景指令。
你（主 session）只負責：寫 task.yaml、呼叫、讀結果、做 judgment
review。迴圈邏輯在 CLI 內，不要自己重新實作。

## 何時用 / 何時不用

- **用**：任務目標明確、驗收條件可寫成 shell 指令（exit 0 = PASS）、
  希望結果由現實（git diff / test / grep）裁決而非 worker 自述
- **不用**：開放式探索或需要互動接管 → `ccs-dispatch`（agentpager
  backend）；同 context 的小任務 → in-harness subagent
- 與 `ccs-dispatch --chain`（agentpager 快速通道，無驗收）是兩層
  獨立機制，不可混用

## 前置

`ccs-dashboard.sh` 已 source 進 shell（依安裝目錄，例：
`source <install-dir>/ccs-dashboard.sh`）。驗收在 `scope.cwd` 指定
的專案目錄執行，需為 git repo（evidence 會抓 `git diff`）。

## 協定四步

### 1. 寫 task.yaml

Schema 與範例見 `references/task-yaml.md`。要點：

- `goal` 是給 worker 的完整任務描述（worker 只看得到它 + 失敗摘要）
- 每條 AC 恰有 `verify.cmd`（machine-checkable）或
  `verify.guidance`（留給 judgment review）之一；至少一條 cmd-track
- AC 品質紀律（integration criteria、security check）：若安裝了
  `plan-quality` skill，依其要求寫 AC

多任務鏈可先寫 chain-spec 再展開（不執行）：

```bash
ccs-dispatch-plan <chain-spec.yaml>   # 產出 next: 串好的 task.yaml 檔
# 人工檢查產出檔後再 dispatch 印出的 entry path
```

### 2. 呼叫

```bash
ccs-dispatch-run <task.yaml>
```

- 前景阻塞直到終態；長任務用 background 執行 + 完成通知，避免乾等
- Exit code：`0` accepted / `10` escalated / `11` hard_stop /
  `2` task 載入失敗 / `1` usage error（無參數）
- 鏈結時注意：exit `0` 只代表**已執行的 hops** 皆 PASS —
  `stop_reason` 為 `failed` / `depth` 時也回 0，是否完整跑完
  要查 `chain.json.stop_reason`
- stdout 印 `run: <run-dir>` 與 outcome 摘要，末尾附一行 advisory
  `suggested trailer: X-Executor: <executor>/<model> (ccs-dispatch-run)`
  （dispatched work 收尾 commit 時 copy 用；`model` 缺省則 executor-only，
  詳 `references/task-yaml.md`）

### 3. 讀結果

結果樹（`<data-dir>/dispatch/runs/<first-id>-chain-NN/`）：

```
chain.json                     # 鏈終態：hops[]、stop_reason、outcome
hop-NN-<task-id>/
├── task.yaml                  # dispatch 當下凍結的驗收條件
├── final.json                 # 本 hop 終態：outcome / attempts
└── attempt-NN/
    ├── prompt.md              # worker 收到的完整 prompt
    ├── executor-output.md     # worker 原始輸出（僅供鑑識，勿當依據）
    ├── git-status.txt / diff.patch   # ground truth
    └── gate/
        ├── <AC-id>.json       # per-AC verdict + exit code + output tail
        └── verdict.json       # 本輪 gate 裁決
```

### 4. Judgment review（Stage 2）

只讀 `diff.patch` + `git-status.txt`（worker 新增的檔案是
untracked，**不會**出現在 diff.patch，要靠 `??` 行發現後另行讀檔）
+ `gate/verdict.json` + guidance-AC 清單，**不要重讀 worker trace**
（fresh-context 紀律；executor-output.md 只在鑑識時看）。你裁決的是 script 抓不到的：是不是對的解、設計
好不好、guidance-AC 過不過。

## Verdict 語意

- `PASS` — 全部 cmd-AC exit 0（guidance-AC 記 `SKIPPED_FOR_LLM`，
  等你 Stage 2 裁決，不參與 gate 判定）
- `RETRY` — 有 FAIL 且 loop_budget 未耗盡；CLI 自動帶「machine 事實
  摘要」（AC id + cmd + exit code，無 worker prose）重派，你不介入
- `ESCALATE` — budget 耗盡。交給人診斷（讀 evidence 樹），
  **不是**由你直接重試 — 你帶著 planning 確認偏誤
- `HARD_STOP` / `ERROR` — 判定函式已支援，目前無 producer
  （現行 AC 執行只產生 PASS / FAIL / SKIPPED_FOR_LLM）

## 鏈結（gated chain）

PASS 後自動跟 `next:`（相對於當前 task.yaml 所在目錄解析）。
停鏈原因記在 `chain.json.stop_reason`：`empty-next`（正常完成）/
`depth` / `cycle` / `failed`（下一檔載入失敗）/ 非 PASS 終態。

## 邊界（現行實作 = Scope C）

- gate + 單次重派；無 tier ladder（重派同 executor）
- executor 為 `claude`（預設）/ `gemini` / `wingman`；claude 與
  gemini 以 auto-approve 跑 headless（claude
  `--permission-mode bypassPermissions`、gemini
  `--approval-mode yolo`）— **gate 為信任邊界**：worker 全權限執行
  於 `scope.cwd`，假成功由 gate 重驗現實攔下；task 應只來自你自己
  的規劃，勿餵不受信任的 goal
- `executor: wingman`（本地 LLM，免 quota）為檔案驅動：task 需帶
  `plan:`（wingman plan.md 路徑，由你依 wingman plan-template 紀律
  撰寫，plan 品質不由 dispatch-run 把關）。wingman 不吃 prompt 前綴
  的重派摘要 → **不重派**（loop_budget 視同 0，gate FAIL 直接
  ESCALATE）；wingman 的 `--exit-status` exit code 與
  `.wingman/result.md` 凍結進 attempt evidence 供診斷，**不參與
  verdict**（gate 是唯一裁決來源，worker 自述樂觀或悲觀皆不信）
- `scope.allowed_paths` / `forbidden_paths` 未實作（僅 `scope.cwd`
  生效），worker 無路徑硬限制
- worker 同步 headless 執行；agentpager async backend 未接入 gate 迴圈
- Stage 2 無自動化（`final.json.stage2` 恆為 null，由你人工執行）
