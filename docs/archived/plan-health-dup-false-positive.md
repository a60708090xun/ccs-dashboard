# Plan: Fix health false positive dup_tool (GH#24)

## Context

`ccs-health` 的 `dup_tool` 指標只計算 Read/Grep 原始重複次數，無法區分合理重複（Read-Edit-Read、不同 offset）和退化重複（compaction 後重讀）。導致重構類 session 容易被誤判為紅燈。

## 方案

修改 `_ccs_health_events()` 的 jq 邏輯，產出「有效重複次數」取代原始次數。`_ccs_health_score()` 不需改動。

### 三條規則

1. **Offset 差異排除** — 同檔案但 offset/limit 不同 → 不算重複
   - 用 composite key `file_path|offset|limit` 取代純 `file_path`
   - 最終 output 仍以 `file_path` 為 key（取同檔案各 key 的 max）

2. **Read-Edit pair 排除** — Read 後有 Edit/Write 同檔案再 Read → 不算重複
   - 追蹤 `_last_edit_seq[file_path]`，比對 Read 間是否有 Edit

3. **Compaction 加權** — 有 `compact_boundary` 後的重複扣全分，無 compaction 扣半分
   - 追蹤 `_compact_seqs[]`，檢查兩次 Read 之間是否有 compaction
   - 半分用 x2 技巧：post-compaction +2, 其他 +1，最終 ÷2

### Compaction 事件格式（已驗證）

```json
{
  "type": "system",
  "subtype": "compact_boundary",
  "content": "Conversation compacted",
  "timestamp": "...",
  "compactMetadata": {
    "trigger": "auto",
    "preTokens": 168365
  }
}
```

### jq accumulator 變更

```
現有:
  tool_reads: {}        # file -> count
  tool_greps: {}        # pattern -> count

新增:
  _seq: 0               # 全域序列號
  _last_read_seq: {}    # "file|offset|limit" -> seq
  _last_edit_seq: {}    # file -> seq
  _compact_seqs: []     # [seq, ...]
  _last_grep_seq: {}    # pattern -> seq
  _dup_reads_x2: {}     # file -> effective_dup * 2
  _dup_greps_x2: {}     # pattern -> effective_dup * 2
```

結尾清理：
```jq
| .tool_reads = (._dup_reads_x2
    | with_entries(.value = ((.value / 2) | floor)))
| .tool_greps = (._dup_greps_x2
    | with_entries(.value = ((.value / 2) | floor)))
| del(._seq, ._last_read_seq, ._last_edit_seq,
      ._compact_seqs, ._last_grep_seq,
      ._dup_reads_x2, ._dup_greps_x2)
```

### 修改檔案

- `ccs-health.sh` — `_ccs_health_events()` jq 邏輯（lines 21-63）

### 測試更新

- `tests/test-health.sh` — 更新既有 fixture 預期值 + 新增 4 個測試案例：
  1. Read-Edit-Read → `tool_reads = 0`
  2. 不同 offset 同檔 → `tool_reads = 0`
  3. compact_boundary 後重讀 → `tool_reads = 1`
  4. 無 compaction 重讀 2 次 → `tool_reads = 0`（0.5 * 2 = 1, ÷2 = 0... 不對）

等等，修正：無 compaction 重讀 **3 次**（first read 不算，2 次 dup × 1 = 2, ÷2 = 1）。

### 既有測試影響

原 fixture `main.sh` 讀 3 次（無 edit、無 compaction）：
- 現在：`tool_reads["/src/main.sh"] = 3`
- 改後：first read 不算 dup, 2 次 dup × 1 (半分) = 2, ÷2 = **1**
- 需更新預期值 `3 → 1`

Badge 測試的 yellow/red fixture（同一 assistant message 內連續 Read）也需調整：
- yellow fixture: 3 次讀 `/x`（無 compaction）→ 2 dup × 1 = 2, ÷2 = **1**（green, 不再 yellow）
- red fixture: 5 次讀 `/a`（無 compaction）→ 4 dup × 1 = 4, ÷2 = **2**（green, 不再 red）
- 需在這些 fixture 加入 `compact_boundary` 事件讓它們維持原等級

## 驗證

1. `bash tests/test-health.sh` 全通過
2. 對真實 session 跑 `ccs-health --json`，確認重構類 session 不再誤判紅燈
3. 含 compaction 的 session 仍能正確偵測退化
