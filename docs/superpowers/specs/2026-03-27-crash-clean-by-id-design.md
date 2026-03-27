# ccs-crash --clean \<id...\>：指定 session ID 直接 archive

ref GH#33

## 背景

`ccs-crash --clean` 目前只有兩種模式：

- interactive（逐一詢問）
- `--clean-all`（批次全部 archive）

缺少「指定特定 session 直接 archive」的能力，
使用者只能靠 interactive 模式跳到目標 session。

## 設計

### 使用方式

```bash
# 單一 session（short ID 或 full UUID）
ccs-crash --clean d25fd727

# 多個 session
ccs-crash --clean d25fd727 a1b2c3d4
```

### ID 匹配規則

每個 `<id>` 對 `crash_map` 的 key 做 prefix match：

- **唯一匹配** — 直接 archive
- **多筆匹配** — 列出所有匹配的 session，
  報錯請使用者用更長的 ID 重試，該 ID 不 archive
- **零匹配** — 報錯「找不到此 ID」

### Confidence 過濾

指定 ID 時**不過濾** low confidence。
使用者明確指定了目標，confidence 過濾無意義。

實作方式：`mode=="clean-id"` 時跳過
現有的 low confidence 過濾邏輯。

### 參數解析

`ccs-crash()` 的 `--clean` 處理調整：

1. 遇到 `--clean` 時，繼續讀取後續參數
2. 非 `--` 開頭的參數收集到 `clean_ids=()`
3. `clean_ids` 有值 → `mode="clean-id"`
4. `clean_ids` 為空 → `mode="clean"`（維持現有 interactive）

### 新增函式

`_ccs_crash_clean_by_id()`：

- 參數：`crash_map`, `session_files`,
  `session_projects`, `clean_ids`
- 對每個 id 做 prefix match
- 成功 → 呼叫 `_ccs_archive_session`
- 輸出格式與 `_ccs_crash_clean_all` 一致

```
  ✓ d25fd727
  ✗ a1b2c3d4 — not found
  ✗ e5f6 — ambiguous (3 matches):
      e5f6a1b2 — project-foo
      e5f6c3d4 — project-bar
      e5f6e7f8 — project-baz

Done: 1 archived, 1 not found, 1 ambiguous
```

### Help 文字

新增：

```
ccs-crash --clean <id...>  Archive specific session(s) by ID (prefix match)
```

## 影響範圍

- `ccs-ops.sh`：修改 `ccs-crash()` 參數解析，
  新增 `_ccs_crash_clean_by_id()` 函式
- 現有行為不受影響：
  `--clean`（無參數）仍是 interactive，
  `--clean-all` 不變
