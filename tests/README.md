# Tests

## 執行測試

```bash
# 全部
bash tests/run-all.sh

# 單一
bash tests/test-core.sh
```

## 新增測試

1. 建立 `tests/test-<module>.sh`
2. `source tests/fixture-helper.sh` 載入 helper
3. `source <module>.sh` 載入待測模組
4. 用 `setup_test_dir "<name>"` 建暫存目錄
5. 用 `cat > "$TEST_DIR/f.jsonl" <<'JSONL'` 建 fixture
6. 用 `assert_eq` / `assert_contains` / `assert_not_contains` 驗證
7. 結尾呼叫 `test_summary`

## Helper API

```
assert_eq LABEL EXPECTED ACTUAL
  完全比對

assert_contains LABEL HAYSTACK NEEDLE
  包含檢查

assert_not_contains LABEL HAYSTACK NEEDLE
  不包含檢查

setup_test_dir NAME
  建 tmp/test-NAME/ + trap cleanup

touch_minutes_ago FILE MINUTES
  mock 檔案時間（GNU coreutils）

strip_ansi
  pipe 用，移除 ANSI codes

test_summary
  印結果，fail > 0 則 exit 1
```
