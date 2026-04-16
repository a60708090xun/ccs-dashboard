# Gemini CLI Session Support Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix Gemini CLI session support in `ccs-dashboard` by aligning the collector and shell helpers with the actual Gemini JSON format (v0.35.2+) and adding `gemini` process detection for accurate crash reporting.

**Architecture:** Update the Python collector to parse Gemini's object-based structure and ISO timestamps. Enhance shell helpers to detect `gemini` processes and handle the specific JSON schema for topics and status.

**Tech Stack:** Bash, Python 3, jq

---

### Task 1: Fix Gemini Collector (`internal/ccs_collect.py`)

**Files:**
- Modify: `internal/ccs_collect.py`

- [ ] **Step 1: Update Gemini topic extraction**

Update `get_gemini_topic` to handle the `messages` array, `type: "gemini"`, and `toolCalls` structure.

- [ ] **Step 2: Update Gemini file processing (timestamps & types)**

Update `process_gemini_file` to handle ISO string timestamps and the object-based structure.

- [ ] **Step 3: Run collector manually to verify**

Run: `python3 internal/ccs_collect.py | grep "|G|"`
Expected: Show Gemini sessions with correct `ago` and `topic`.

- [ ] **Step 4: Commit**

```bash
git add internal/ccs_collect.py
git commit -m "fix(collector): support Gemini v0.35+ JSON format and ISO timestamps"
```

---

### Task 2: Update Crash Detection for Gemini Processes

**Files:**
- Modify: `ccs-core.sh`

- [ ] **Step 1: Add `gemini` process detection**

Modify `_ccs_detect_crash()` to include `gemini` in `pgrep` and `running_sids`.

- [ ] **Step 2: Fix Gemini `mtime` extraction in crash detection**

Update the logic to parse `lastUpdated` as an ISO string using `date -d`.

- [ ] **Step 3: Run crash detection check**

Run: `source ./ccs-dashboard.sh && ccs-crash --json`
Expected: Gemini sessions currently running are NOT marked as crashed.

- [ ] **Step 4: Commit**

```bash
git add ccs-core.sh
git commit -m "fix(core): add gemini process detection and fix ISO timestamp parsing in ccs-crash"
```

---

### Task 3: Align Core Helpers with Gemini Object Format

**Files:**
- Modify: `ccs-core.sh`

- [ ] **Step 1: Update `_ccs_topic_from_jsonl` for Object Format**

Update `_ccs_topic_from_jsonl` to use the correct `jq` filters for the Gemini object structure (`.messages[]`, `.type == "gemini"`, etc.).

- [ ] **Step 2: Verify with `ccs-active`**

Run: `source ./ccs-dashboard.sh && ccs-active`
Expected: Gemini topics are correctly displayed.

- [ ] **Step 3: Commit**

```bash
git add ccs-core.sh
git commit -m "fix(core): update _ccs_topic_from_jsonl to support Gemini object-based structure"
```
