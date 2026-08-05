# task.yaml 契約（ccs-dispatch-run）

> **SoT 宣告**：本檔為 task.yaml 的使用者面契約，以
> `ccs-dispatch.sh` 現行實作為準；`docs/internal/` 的 spec drafts
> 為設計史料。schema 變更走本檔 + CHANGELOG。

## 欄位

| 欄位 | 必填 | 型別 / 限制 |
|------|------|-------------|
| `id` | Yes | 非空字串；同時是 run 目錄名前綴 |
| `goal` | Yes | 非空字串；worker 收到的任務描述全文 |
| `scope.cwd` | No | worker 執行與 gate 驗收目錄；預設 `.`（呼叫時的 cwd）；建議寫絕對路徑 |
| `executor` | No | `claude`（預設）\| `gemini` \| `wingman`；頂層字串欄位。claude/gemini 以 auto-approve 跑 headless（gate 為信任邊界，見 SKILL.md § 邊界）；wingman 為本地 LLM 檔案驅動，需 `plan:` |
| `backend` | No | `headless`（預設）\| `agentpager`；頂層字串欄位。`agentpager` 讓 gate worker 跑在 agent-pager 互動 local channel（tmux、可監看/接管），gate 以前景阻塞式 spawn+wait 等 per-attempt handoff 檔為完成訊號，回來後照常對現實驗收（gate 仍是唯一裁決來源）；bounded wait（逾 `timeout_sec` 收回 seat）。`executor` 映射為互動 worker CLI（claude\|gemini）；`agentpager` + `wingman` 不合法 |
| `model` | No | 頂層字串欄位；派工者宣告本次執行用的 model。**會實際生效**：headless 帶 `-m`（gemini）/ `--model`（claude），`backend: agentpager` 則寫進 launch 檔的 `model:` 欄（由 agent-pager 的 registry 解析 alias）。缺省 = 沿用該 CLI 自己記住的預設。`executor: wingman` 為檔案驅動、無 model 旗標，該欄僅作 provenance。同時供收尾 auto-suggest 的 `X-Executor` trailer 填 `<model>` 段（缺省時退化為 executor-only） |
| `plan` | 僅 wingman | 與 `executor: wingman` 互為充要（缺一驗證失敗）；wingman plan.md 路徑，相對**本檔所在目錄**解析（同 `next:`），執行時轉絕對路徑傳給 `wingman execute --plan`。plan 依 wingman plan-template 紀律由派工者撰寫 |
| `next` | No | 下一個 task.yaml 路徑；相對路徑以**本檔所在目錄**解析。**與 worker handoff frontmatter 的同名欄位不同型別**：那邊的 `next:` 是散文一行，在 `ccs-dispatch --chain`（非同步鏈）會被原樣拼進下一 hop 的 prompt。**`ccs-dispatch-run` 的 gated chain 只讀本檔的 `next:`，不讀 worker handoff**。在 handoff 寫路徑不會報錯，只會讓非同步鏈的下一個 worker 收到一行沒有語境的路徑 |
| `execution_policy.loop_budget` | No | 重派上限；預設 1（共 2 attempts）；0 = 不重派。`executor: wingman` 一律視同 0（重派摘要走 prompt 前綴，wingman 吃不到；feedback 迴圈為 followup） |
| `execution_policy.timeout_sec` | No | worker 與單條 AC 的 timeout；預設取 `CCS_DISPATCH_TIMEOUT`（600） |
| `acceptance_criteria[]` | Yes | 非空陣列；規則見下 |

## acceptance_criteria 規則（載入時強制驗證）

- `id`：必填，`^[A-Za-z0-9_.-]+$`（直接用作 evidence 檔名），全 task 內唯一
- `text`：外部可觀察行為描述（給人讀；載入器不驗證但必寫）
- `verify`：**恰好一個**：
  - `cmd`：bash predicate，於 `scope.cwd` 執行，exit 0 = PASS、
    非零 = FAIL（timeout 回 124 = FAIL）
  - `guidance`：prose 判準，gate 不執行，記 `SKIPPED_FOR_LLM`
    交 Stage 2 裁決
- **至少一條 cmd-track**（全 guidance 會 auto-PASS，破壞 gate 意義，
  載入直接失敗）

## AC 撰寫紀律

- **反假陽性基線驗證**：count / pattern 類 AC 的門檻，先對
  pre-change 基線跑過同一 predicate、確認改動前為 FAIL 再凍結——
  否則 AC 可能改動前即 PASS，gate 對該面向失去裁決力
- **負向 AC 碰撞檢查**（wingman plan-passthrough 尤其）：`! grep`
  類 AC 凍結前，對 plan 內給定的代碼**含註解字面**跑同一
  predicate——基線驗證擋不住 plan 自帶的字面碰撞，gate 會 FAIL
  在正確的實作上。（下面「負向 AC 只掃 diff 新增行」那條同時緩解本條：
  掃描範圍縮到新增行後，plan 內既有字面不再命中）
- **AC 逐字寫在 YAML block scalar，不要先經 markdown table**：table 需要
  把 pipe 逃脫成 `\|`，而 ERE 的 `\|` 是**字面 pipe、不是 alternation**
  （實測 `grep -nE '/a/\|/b/'` 對 `/a/x` 回 rc=1，只對含完整字面字串
  `/a/|/b/` 的行才回 rc=0）——逃脫過的 AC 通常永遠不 match，變成永遠
  PASS 的橡皮圖章
- **「沒動到 X」類 AC 錨在派工前的 base commit**，不要用裸 `git diff`：
  後者比的是 working tree vs index，worker 只要 `git add` 就回 rc=0
  （實測：改檔後 `git diff --quiet` rc=1、`git add` 之後 rc=0，而同一
  時點 `git diff HEAD --quiet` 仍 rc=1）→ 該 AC vacuously PASS，而這類
  AC 往往正是唯一擋住 worker 改動既存檔案的機制。**`git diff HEAD` 與
  `git status --porcelain` 只擋到這一步**——worker 再 commit 一次，兩者
  一起變乾淨（實測皆回「無差異」）。派工前記下
  `BASE=$(git rev-parse HEAD)`，AC 用 `git diff "$BASE" -- <path>`，
  或另加一條 `test "$(git rev-parse HEAD)" = "<base-sha>"`
- **負向 AC 只掃 diff 的新增行，不要掃整份檔案**：規則文件常把要禁的
  pattern 當示例寫在自己內文裡，整檔掃描於是恆紅；而恆紅 AC 對 cheap
  worker 是「把那條規則刪掉」的誘因。寫法：

  ```
  ! git diff "$BASE" -U0 --no-color -- <path> \
    | grep -E '^\+' | grep -vE '^\+\+\+ ' | grep -E '<pattern>' >/dev/null
  ```

  三個細節都是實測踩出來的：`--no-color`（目標 repo 若設
  `color.ui = always`，diff 行帶 ANSI escape，`^\+` 全部不匹配 → 整條
  靜默 PASS）、用 `grep -vE '^\+\+\+ '` 濾檔頭而非 `^\+[^+]`（後者會漏掉
  內容本身以 `+` 開頭的新增行）、末段 `grep … >/dev/null` 而非 `grep -q`
  （`-q` 提早退出使上游收 SIGPIPE，在有 `pipefail` 的 shell 下整條反轉成
  PASS）。**涵蓋範圍：只涵蓋 tracked 檔案的修改**——worker **新建**的檔案
  不在 `git diff` 裡（實測回 PASS），要納入須先
  `git add -N -- <path>`，或對該檔改掃整檔。凍結前對一個**故意含
  pattern** 的暫時 diff 跑一次，確認會 FAIL——路徑打錯或檔案不存在時
  diff 為空，這條會恆 PASS 而不報錯
- integration 類：驗「元件被呼叫」不只「檔案存在」
  （例：`grep -q 'from .greeter import' src/cli.py`）
- 涉及 credential 的 task：加一條
  `! grep -rn "password\|api_key" <src>/` 類 AC
- 若安裝了 `plan-quality` skill，依其完整要求
- cmd 以 `bash -c` 於 `scope.cwd` 執行，不繼承 aliases 與非 export
  的 shell 狀態（exported env vars 會繼承）— 別依賴你 session 的
  互動環境；依賴工具（pytest 等）需在 `scope.cwd` 專案內可用

## 完整範例

```yaml
id: greeter-module
goal: |
  在 src/greeter.py 新增 greet(name) 函式並讓 cli.py 實際呼叫它。
  greet 回傳 "Hello, <name>!"。加 pytest 單元測試。
scope:
  cwd: "/abs/path/to/project"
executor: claude
next: "greeter-docs.task.yaml"        # 可省略
execution_policy:
  loop_budget: 1
  timeout_sec: 900
acceptance_criteria:
  - id: AC1
    text: "greet 函式存在"
    verify:
      cmd: "grep -q 'def greet(name' src/greeter.py"
  - id: AC2
    text: "單元測試通過"
    verify:
      cmd: "pytest tests/test_greeter.py -q"
  - id: AC3
    text: "greeter 被 cli.py 實際呼叫（非 dead code）"
    verify:
      cmd: "grep -q 'from .greeter import\\|import greeter' src/cli.py"
  - id: AC4
    text: "錯誤處理與專案既有 pattern 一致"
    verify:
      guidance: "對照 src/loader.py 的 exception handling 慣例"
```

## chain-spec（多任務展開）

`ccs-dispatch-plan <chain-spec.yaml>` 把一份 spec 展開成 next: 串好
的 task.yaml 檔（不執行；產出後人工檢查再 dispatch）：

```yaml
defaults:                      # 淺層 merge 進每個 hop（hop 覆蓋 defaults）
  scope: { cwd: "/abs/path/to/project" }
  execution_policy: { loop_budget: 1 }
hops:
  - id: step-one
    goal: "..."
    acceptance_criteria: [ ... ]
  - id: step-two
    goal: "..."
    acceptance_criteria: [ ... ]
```

產出 `hop-01-step-one.task.yaml`、`hop-02-step-two.task.yaml`
（自動 wire `next:`，末 hop 無），每檔皆過載入驗證才落地。
`model` 走一般 dict merge（可放 `defaults` 或個別 hop），照常存活。

## Executor provenance trailer（收尾 auto-suggest）

`ccs-dispatch-run` 收尾時，除了 `run:` / `outcome:` 摘要，另印一行
**advisory** commit trailer，供收尾 commit 的人直接 copy：

```
suggested trailer: X-Executor: <executor>/<model> (ccs-dispatch-run)
```

- `<executor>` 取自 task 的 `executor`（省略時為 `claude`）；`<model>`
  取自 task 的 `model`，缺省時退化為 `X-Executor: <executor>
  (ccs-dispatch-run)`（無斜線）。
- 對所有終態（accepted / escalated / hard_stop）皆印——慣例涵蓋
  escalate 後由 orchestrator 收尾 commit 的情形。
- chain 內出現多個不同 executor 時，每個 distinct 的 `executor[/model]`
  各印一行。
- 純 advisory：dispatch-run 不 commit、不強制。此 trailer 與
  `Co-Authored-By`（orchestrator 署名）語意正交，表「實作由哪個
  dispatched executor 產出」；慣例只往前生效，不追改既有 commit。
