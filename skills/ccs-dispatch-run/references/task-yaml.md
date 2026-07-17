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
| `plan` | 僅 wingman | 與 `executor: wingman` 互為充要（缺一驗證失敗）；wingman plan.md 路徑，相對**本檔所在目錄**解析（同 `next:`），執行時轉絕對路徑傳給 `wingman execute --plan`。plan 依 wingman plan-template 紀律由派工者撰寫 |
| `next` | No | 下一個 task.yaml 路徑；相對路徑以**本檔所在目錄**解析 |
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
