# GH#15: 拆分 ccs-dashboard.sh 為模組化 source files

## Context

`ccs-dashboard.sh` 已達 4687 行，包含 7 個獨立 command group。
單檔難以維護、review、定位問題。
本次重構目標：拆成模組檔案，對使用者零影響。

## 拆分方案

### 目標結構

```
ccs-core.sh        (~960)  基礎 + 搬入共用 helper
ccs-dashboard.sh   (~400)  入口 + source + status/pick
ccs-viewer.sh      (~490)  ccs-details + ccs-html
ccs-handoff.sh     (~420)  ccs-handoff + ccs-resume-prompt
ccs-overview.sh    (~800)  ccs-overview + render helpers
ccs-feature.sh     (~900)  feature clustering + ccs-tag
ccs-ops.sh         (~900)  ccs-crash + ccs-recap + ccs-checkpoint
ccs-dispatch.sh    (~455)  不動
ccs-health.sh      (~430)  不動
```

### Step 1: 搬共用 helper 到 ccs-core.sh

從 ccs-dashboard.sh 搬到 ccs-core.sh 尾端：

| Helper | 行數 | 被誰用 |
|---|---|---|
| `_ccs_data_dir()` | ~8 | 5+ 模組 |
| `_ccs_collect_sessions()` | ~50 | 5 模組 |
| `_ccs_ago_str()` | ~12 | 4 模組 |

### Step 2: 建立 ccs-viewer.sh

從 ccs-dashboard.sh 搬出：
- `ccs-html()` (L554–L789)
- `ccs-details()` (L791–L1043)

### Step 3: 建立 ccs-handoff.sh

從 ccs-dashboard.sh 搬出：
- `ccs-handoff()` (L1045–L1264)
- `ccs-resume-prompt()` (L1266–L1461)

### Step 4: 建立 ccs-overview.sh

從 ccs-dashboard.sh 搬出：
- `_ccs_overview_session_data()` (L1462)
- `_ccs_overview_md/json/todos/files/git/terminal()`
- `ccs-overview()` (L3587)

### Step 5: 建立 ccs-feature.sh

從 ccs-dashboard.sh 搬出：
- `_ccs_extract_issue_ref()` (L2359)
- `_ccs_branch_slug()` (L2365)
- `_ccs_read_overrides()` (L2370)
- `_ccs_feature_status/cluster/icon/md/json/terminal()`
- `_ccs_feature_detail_md/timeline_md()`
- `ccs-feature()` (L3106)
- `ccs-tag()` (L3164)

### Step 6: 建立 ccs-ops.sh

從 ccs-dashboard.sh 搬出：
- `_ccs_crash_md/json()`, `_ccs_archive_session()`
- `_ccs_crash_clean/clean_all()`, `ccs-crash()`
- `_ccs_detect_last_workday()`, `_ccs_recap_*()`, `ccs-recap()`
- `_ccs_checkpoint_*()`, `ccs-checkpoint()`

### Step 7: 更新 ccs-dashboard.sh 入口

ccs-dashboard.sh 只保留：
- source 各模組的 statements
- `ccs-status()` + `_ccs_status_md()` (~170 行)
- `ccs-pick()` (~150 行)
- 檔案頭註解更新

Source 順序：
```bash
source "${BASH_SOURCE[0]%/*}/ccs-core.sh"
source "${BASH_SOURCE[0]%/*}/ccs-health.sh"
source "${BASH_SOURCE[0]%/*}/ccs-viewer.sh"
source "${BASH_SOURCE[0]%/*}/ccs-handoff.sh"
source "${BASH_SOURCE[0]%/*}/ccs-overview.sh"
source "${BASH_SOURCE[0]%/*}/ccs-feature.sh"
source "${BASH_SOURCE[0]%/*}/ccs-ops.sh"
source "${BASH_SOURCE[0]%/*}/ccs-dispatch.sh"
```

### Step 8: 更新 install.sh

- 新增所有模組檔案的存在檢查
- 新增所有模組的 `bash -n` syntax check
- commands 列表不變（對使用者零影響）

### Step 9: 更新文件

- README 的檔案結構描述
- commands.md 如有模組路徑引用

## 設計原則

- `ccs-dashboard.sh` 保持唯一入口（.bashrc 只 source 它）
- 各模組只依賴 `ccs-core.sh` 的 helper
- `install.sh` 不需改動 source line（只加檔案檢查）
- 所有指令名稱、參數、行為不變

## 驗證方式

1. `bash -n` 所有模組檔案
2. `source ccs-dashboard.sh` 不報錯
3. 逐一測試各指令仍正常運作：
   - `ccs-status`, `ccs-pick 1`
   - `ccs-html`, `ccs-details`
   - `ccs-handoff`, `ccs-resume-prompt`
   - `ccs-overview`, `ccs-overview --todos-only`
   - `ccs-feature`, `ccs-tag`
   - `ccs-crash`, `ccs-recap`, `ccs-checkpoint`
   - `ccs-dispatch --help`, `ccs-jobs`
4. 確認總行數一致（不遺漏、不重複）
