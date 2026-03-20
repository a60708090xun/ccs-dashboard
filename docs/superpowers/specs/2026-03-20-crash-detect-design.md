# ccs-crash: Crash-Interrupted Session Detection

- **Issue:** GitHub #9
- **Date:** 2026-03-20
- **Status:** Draft (rev2 — spec review fixes)

## Background

Server 異常重開機（kernel crash、OOM killer、斷電等）或 process 意外死亡時，active session 的 agent 會中斷。目前沒有內建方式識別哪些 session 被影響，使用者需要手動逐一檢查。

## Architecture: Detection Layer + Display Integration

偵測邏輯抽成獨立 helper，`ccs-crash` 指令和 `ccs-overview` 共用。

```
_ccs_detect_crash()          ← helper（ccs-core.sh）
       │
       ├── ccs-crash          ← 獨立指令，完整報告
       └── ccs-overview       ← 整合顯示，banner + session 標記
```

## Detection Logic

### `_ccs_detect_crash()`

**位置：** `ccs-core.sh`

**參數：**
- `--reboot-window N` — Path 1 crash window 寬度（分鐘），預設 30
- `--idle-window N` — Path 2 idle window 寬度（分鐘），預設 1440（24h）
- `--json` — 輸出 JSON 而非路徑列表

**Usage modes:**
- **Within `_ccs_collect_sessions` loop:** session 已通過 `last-prompt` 和 subagent 過濾，不需重複檢查
- **Standalone（`ccs-crash` 呼叫）：** 需自行過濾 archived session（有 `last-prompt` marker）

**兩條偵測路徑：**

### Path 1: Reboot Detection

```
boot_epoch = date -d "$(uptime -s)" +%s
window_start = boot_epoch - (window * 60)
upper_bound = boot_epoch + 120             # 容忍 filesystem replay + NTP correction 誤差

for each session JSONL (from _ccs_collect_sessions):
  mtime = stat -c "%Y" "$f"
  if mtime >= window_start AND mtime < upper_bound:
    → crash-interrupted (high confidence)
```

- `uptime -s` 不需 root；不可用時 fallback 到 `who -b`
- 重開機後所有舊 process 都死了，不需 `kill -0` 確認

### Path 2: Non-Reboot Detection

機器沒重開，但 session process 異常死亡。

```
for each session JSONL (from _ccs_collect_sessions):
  mtime 在最近 idle_window 內（預設 1440m / 24h）
  AND 沒有 "last-prompt" marker（不是正常結束）
      （在 _ccs_collect_sessions loop 內時已過濾，standalone 時需自行檢查）
  AND ps 裡找不到 --resume <session-id> 的 process

  # Interrupt signal detection（raw JSONL parsing）：
  # 取最後一個 type=assistant 的 message，檢查其 content array：
  #   - content 全為 tool_use/thinking，無 text entry → mid-execution crash（high）
  #   - content 為空 array 或 message 不存在 → mid-response crash（high）
  #   - content 有 text 但 process 已死 → 可能是手動 Ctrl+C（low）

  if 最後 assistant message 的 content 無 text entry 或不存在:
    → crash-interrupted (high confidence)
  else:
    → crash-interrupted (low confidence)
```

### Confidence Levels

| Level | Condition | False Positive Risk |
|-------|-----------|---------------------|
| high | Path 1（reboot + mtime in window）| Extremely low |
| high | Path 2 + explicit interrupt signal（`⚡ interrupted` / empty response）| Very low |
| low | Path 2 + no explicit signal（could be manual Ctrl+C）| Moderate |

## CLI Interface

```
ccs-crash [--reboot-window N] [--idle-window N] [--md|--json] [--all] [--help|-h]

Options:
  --reboot-window N   Path 1 crash window width in minutes (default: 30)
  --idle-window N     Path 2 idle window width in minutes (default: 1440 / 24h)
  --md                Markdown output (default)
  --json              JSON output
  --all               Include low confidence results AND subagent sessions
                      (default: high confidence only, no subagents)
  --help, -h          Show usage
```

### `--md` Output

```markdown
## ⚠️ Crash-Interrupted Sessions (boot: 2026-03-20 09:47)

### 🔴 b9acc81f — specman/cases — Exp-G5 分析
- **最後活動：** 09:38（crash 前 9 分鐘）
- **最後訊息：** 好
- **Todos：** 3/3 ✓
- **Git：** master (4 uncommitted files)
- **Resume：** `claude --resume b9acc81f-...`

### 🟡 d25fd727 — specman — Exp-G5 prompt optimization  [--all]
- **最後活動：** 09:20（空回應）
- ...
```

### `--json` Output

```json
{
  "boot_time": "2026-03-20T09:47:01+08:00",
  "reboot_window_minutes": 30,
  "idle_window_minutes": 1440,
  "sessions": [
    {
      "session_id": "b9acc81f",
      "session_uuid": "b9acc81f-9680-4a84-a8df-4aebeaefe11d",
      "confidence": "high",
      "detection_path": "reboot",
      "project": "works/git/specman/cases",
      "topic": "Case 008: Exp-G5 分析",
      "last_activity": "2026-03-20T09:38:00+08:00",
      "last_user_message": "好",
      "todos": [
        {"content": "...", "status": "completed"}
      ],
      "git": {
        "branch": "master",
        "uncommitted_files": 4
      },
      "resume_command": "claude --resume b9acc81f-9680-4a84-a8df-4aebeaefe11d"
    }
  ]
}
```

## Overview Integration

### `ccs-overview --md`

有 crash-interrupted session（high confidence）時，header 加 banner：

```markdown
# Work Overview (2026-03-20 11:11)

> ⚠️ **偵測到 3 個 crash-interrupted session**（系統重開機 09:47）
> 執行 `ccs-crash` 查看詳情，或 `ccs-crash --all` 含低信心結果
```

Session 列表中被影響的 status icon 改為 `🔴`（取代原本的 `🟢`/`🔵`/`🟡`）。

### `ccs-overview --json`

頂層加 `crash_detected` 欄位：

```json
{
  "crash_detected": {
    "boot_time": "2026-03-20T09:47:01+08:00",
    "affected_sessions": ["b9acc81f", "806f4760", "ef34383c"],
    "count": 3
  },
  "sessions": [
    {
      "session_id": "b9acc81f",
      "crash_interrupted": true,
      "crash_confidence": "high",
      ...
    }
  ]
}
```

沒有偵測到 crash 時，`crash_detected` 為 `null`，session 上不加 `crash_interrupted` 欄位。

### Integration Point

`_ccs_detect_crash()` is called once in `ccs-overview()` before dispatching to the renderer. Results are stored in a nameref associative array (session_id → confidence) and passed to `_ccs_overview_md()` / `_ccs_overview_json()`.

### Performance

`_ccs_detect_crash()` 在 `_ccs_collect_sessions` loop 中順帶執行：
- `uptime -s` 只呼叫一次 → epoch 比對是 O(1) per session
- Path 2 的 `ps` 查詢只在 Path 1 無結果時才跑
- 不額外跑第二輪 session 掃描

## Edge Cases

| Case | Handling |
|------|----------|
| Multiple reboots in short time | `uptime -s` only gives last boot; intermediate sessions covered by window or too old |
| mtime shifted by journal recovery | Upper bound = `boot_epoch + 120` tolerates ±120s |
| Session already resumed after reboot | mtime updated → falls outside crash window → not flagged |
| Subagent sessions | Skipped by default (consistent with `_ccs_collect_sessions`); included with `--all` |
| `uptime -s` unavailable (containers) | Fallback to `who -b`; both fail → Path 1 skipped, Path 2 only; stderr warning |
| Clock skew / NTP jump after reboot | Upper bound extended to `boot_epoch + 120` to tolerate NTP correction |
| Corrupt / empty JSONL | Skip gracefully, consistent with `_ccs_session_row` error handling |
| Archived session (has `last-prompt`) | Crash-interrupted sessions by definition lack `last-prompt`, so always included by `_ccs_collect_sessions`. Standalone mode must filter independently |
| Orchestrator skill | Agent uses `crash_detected` JSON field for context-aware options; no skill file changes needed |

## Implementation Scope

### Files to modify:
1. **`ccs-core.sh`** — add `_ccs_detect_crash()` helper
2. **`ccs-dashboard.sh`** — add `ccs-crash` command, integrate into `_ccs_overview_json()` and `_ccs_overview_md()`
3. **`docs/commands.md`** — document `ccs-crash` command

### Not in scope:
- Historical crash log / persistence
- Automatic resume of interrupted sessions
- Hook-based auto-trigger on boot
