# Failure Triage SOP: Confabulation-Family Model Failures

This document describes how to diagnose and triage confabulation-family failures —
a class of LLM model-side failure where the model's narrative diverges from ground truth.
These failures share a common structure: the model fabricates or misrepresents facts
(tool outputs, user questions, commit hashes, file existence) and may double down when
challenged, sometimes inventing external villains to protect narrative coherence. They
are distinct from harness bugs, MCP connectivity errors, or API quota failures — the
infrastructure is functioning correctly, but the model's internal state has drifted from
reality.

**Quick start:**

```bash
ccs-failure-triage --help    # usage reference
ccs-failure-triage --sop     # print this SOP summary inline
ccs-failure-triage <session-id>   # run auto-triage on a session
```

---

## Failure family: sub-patterns

- **Sub-pattern A — Imagined user question:** The model proactively answers a question
  the user never asked, often wrapping it in apologetic phrasing ("sorry for the wait",
  "let me be direct about your question").

- **Sub-pattern B — Fabricated tool output:** The model asserts in `assistant.text` that
  a commit hash, PR URL, or file write succeeded, but the corresponding `tool_result`
  contradicts it or no matching `tool_use` exists.

- **Sub-pattern C — Externalized blame:** After being corrected by the user, the model
  invents an external villain ("tool poisoning", "harness injection", "prompt hijacking")
  to preserve narrative consistency rather than acknowledging fabrication.

- **Sub-pattern D — Self-correction prose ahead of reality:** Phrases like
  "I need to stop and be honest" or "let me get the ground truth" appear, but the
  "prior measurement" or "earlier prompt" they reference does not exist in the transcript.

---

## When to use this SOP

Trigger on any of the following (one is sufficient):

- User says "doesn't add up", "that's not what I asked", "you said it worked but it didn't"
- User sees a success message but git/gh/filesystem state contradicts it
- You are taking over a session and the narrative does not match ground truth
- After multiple correction rounds the model still claims "this time it's real" but
  evidence does not align

**Do not use for:** pure harness / MCP / environment issues where the model's narrative
is not involved.

---

## Prerequisites

Before starting:

```
1. Session ID or transcript JSONL path
2. Approximate timestamp when the user noticed the mismatch (rough is fine)
3. A clean session — do not debug a contaminated session from within itself;
   the model's narrative coherence drive will cause the forensic to also confabulate
```

Transcripts are stored at `~/.claude/projects/<proj-slug>/<session-id>.jsonl`.

---

## Common detection signatures

The following signatures appear across multiple cases. Use these when writing new case
studies or doing a quick manual scan before running auto-triage.

1. **Narrative vs ground-truth contradiction:** `assistant.text` claims X, but the same
   turn's `tool_result` (or user prompt history) has no supporting evidence.

2. **Self-correction phrasing with no source:** Phrases like "let me be direct about your
   question (sorry for the wait)", "I need to stop and be honest immediately",
   "Let me get the ground truth before..." appear, but the "prior question" or
   "measured number" they reference is not in the transcript.

3. **Long-turn-end prose:** Large `stop_hook_summary.durationMs`, multiple `assistant.text`
   segments in a single turn without user intervention, and the final segment is
   reflective or corrective prose.

4. **Externalized blame after correction:** When the user points out a contradiction,
   the model fabricates an "environment/tool/harness was compromised" hypothesis to
   maintain narrative consistency rather than admitting fabrication.

5. **Trigger source is neutral technical vocabulary in user documents:** When the model
   suddenly declares it has been "injected/poisoned/attacked", check the documents
   the user recently had the model read for neutral uses of "injection / poisoning /
   prompt injection" (describing mechanisms, citing papers, translating technical blogs).
   The model may misread neutral vocabulary as evidence of an active attack.

6. **Paranoid metric fabrication:** The model defines and reports its own metrics such as
   "inject 0, fake_refs 0, real_refs 9 ✓" or "END marker intact" — these are not
   tool output, they are the model's invented "lab test". This is a Sub-pattern B
   variant: instead of fabricating real git/gh state, it fabricates a fictional
   verification system.

7. **Cross-channel verification accumulation:** The same fact (file content, commit hash)
   is verified using grep, git hash-object, python3, od, and multiple other methods,
   and each time reports "consistent". On the surface this looks thorough; in practice,
   if the thing being verified was never the actual attack target, this is a paranoid
   loop signature rather than engineering discipline.

---

## Phase 0: Collect metadata (< 1 min)

```bash
TR=~/.claude/projects/<proj-slug>/<session-id>.jsonl

# Model version
python3 -c "
import json
from collections import Counter
c = Counter()
with open('$TR') as f:
    for line in f:
        o = json.loads(line)
        if o.get('type') == 'assistant':
            m = (o.get('message') or {}).get('model')
            if m: c[m] += 1
for m,n in c.most_common(): print(m, n)
"

# Session time window + size
wc -l "$TR"
head -3 "$TR" | python3 -c "
import sys, json
for line in sys.stdin:
    o = json.loads(line)
    ts, cwd, ver = o.get('timestamp'), o.get('cwd'), o.get('version')
    if ts: print('first:', ts, '|', cwd, '|', ver); break
"
tail -3 "$TR" | python3 -c "
import sys, json
last = None
for line in sys.stdin:
    o = json.loads(line)
    if o.get('timestamp'): last = o
if last: print('last :', last.get('timestamp'))
"
```

**Interpretation:**

- If the model is Opus 4.8 or later generation → confabulation family risk is elevated
  (per case studies and [GitHub issue #63884](https://github.com/anthropics/claude-code/issues/63884))
- If the session is long (> 100 turns or > 2 hours) → long-turn drift risk is high
- If the session spans midnight or the `cwd` jumps between records → session was not
  cleanly cut, context bloat amplifies confabulation

---

## Phase 1: Auto-triage (2–3 min)

Run the bundled script. Two input modes:

```bash
# Mode A: bare session id — cd to the project root first
cd /path/to/project
ccs-failure-triage <session-id>

# Mode B: project label (<project>:<6-hex-short>) — no cd needed;
#         project root is auto-resolved from transcript metadata
ccs-failure-triage myproject:abc123

# Script prints:
#   Input mode:    sid | label
#   Session id:    <full-uuid>
#   Project root:  <auto-resolved>
#   Transcript:    <path>
#   Wrote: <project>/tmp/<sid>-triage-<YYYY-MM-DD>.md
#   Summary (last section of the report):
#   ...
# Then use less or Read to inspect the full report
```

**Transcript resolution rules:**

- **Mode A (bare sid):** resolves to `~/.claude/projects/<slug>/<sid>.jsonl`, where
  `<slug>` is the project root path with `/` replaced by `-` (matching Claude Code's
  own naming). Project root is auto-detected via `git rev-parse --show-toplevel`,
  falling back to `pwd`.
- **Mode B (label):** globs `~/.claude/projects/*/<short>*.jsonl` to locate the
  transcript; project root is read from the first record containing `cwd`. If the short
  prefix is ambiguous, the error message will guide you to use the full session ID.

**Resolving a label to session ID:**

```
label format: <project>:<6-hex-short>
short = first 6 characters of the session UUID
glob  ~/.claude/projects/*/<short>*.jsonl
```

The script produces 5 checks:

1. **Model & session shape** — version, length, turn count, longest turn
2. **User prompt history** — all real user prompts (excluding caveats / skill launches /
   tool_results), in chronological order
3. **Multi-text-segment turns** — positions where the assistant emits multiple
   consecutive `text` segments in one turn without user intervention —
   **strong signal for Sub-pattern A/D**
4. **Phrasing red flags** — all occurrences of self-correction / apology phrasing
   in both Chinese and English
5. **Narrative vs tool_use divergence** — commit hashes, PR URLs, file paths appearing
   in `assistant.text` that have no matching evidence in preceding `tool_result` entries —
   **strong signal for Sub-pattern B**

**Interpretation rules:**

```
Check 3 hit + Check 4 hit + Check 2 has no matching prompt   → Sub-pattern A likely
Check 5 hit                                                  → Sub-pattern B — verify first
Check 4 hit + assistant mentions "tool poisoning / injection" → Sub-pattern C
Check 3 + Check 4 both hit at end of turn                   → Sub-pattern D
```

### False positive calibration

Not every Check 5 hit is fabrication. Before escalating to Phase 2, apply these
calibration rules:

**Check 5 / Sub-pattern B — SDA orchestrator sessions**

An SDA orchestrator naturally mentions commit hashes in prose summaries after `gh pr merge`
or `git log` tool calls. The tool call returns a PR URL or merge confirmation — **not the
hash** — so the hash only appears in the orchestrator's prose summary, which is written
from prior context. Check 5 flags it as "not in tool_result", but the hash is real.

Confirm before escalating:

```bash
git -C <repo> cat-file -t <flagged-hash>
# commit  → hash is real, this is a false positive
# missing object  → fabricated, proceed to Phase 2
```

**Check 5 / Sub-pattern B — small PR numbers (#1–#9)**

The PR number regex matches step numbers, task labels, and check counters in prose
("Task #3", "Check #5", etc.). A PR reference is more likely a false positive when:

- The number is ≤ 9 and no other PR context appears in the turn
- The repo has far more than 9 PRs open/closed

Confirm with `gh pr view <N> --repo <owner/repo>` — if the PR does not exist, the
number was a regex false positive.

**Check 3 — multi-text-segment turns in SDA sessions**

An SDA orchestrator routinely emits multiple text segments per turn (task dispatch,
progress note, reviewer summary). Multi-segment turns are structural in SDA and are
**not** a confabulation signal on their own. Only escalate Check 3 hits when they also
co-occur with Check 4 (phrasing red flags) or when the final segment is reflective prose
with no preceding user prompt.

**General rule:**

A Check 5 or Check 3 hit from a **Sonnet-class** model in an SDA session should be
treated as probable false positive unless `git cat-file` or `gh pr view` confirms the
artifact does not exist. Sonnet-class confabulation rates in SDA sessions are
structurally much lower than Opus 4.8 long-turn rates; the baseline for each model
generation differs significantly.

**Investigating confabulation triggers confabulation detectors**

A session whose purpose is to *diagnose* or *discuss* a prior confabulation will
naturally contain the same vocabulary (injection, poisoning, fabricated hash, tampered
channel) that the detectors look for. Check 4 and Check 5 false positives are therefore
expected when:

- The session opened with a prompt like "上個 session 歪掉了，狀況是？" (investigate
  prior session) or "上個 session 分析到一半歪掉了" and the model read a file
  written by that prior session
- The session's tool_use includes reading `tmp/*-retrospective.md`,
  `tmp/*-incident-report.md`, or any other artifact produced by a suspected confabulation
  session

In these cases, Check 4 phrasing hits are the model *quoting or analysing* the prior
session's confabulation narrative, not producing its own. Confirm by checking whether
the hit phrases appear in `assistant.text` after a Read/Bash that loaded the prior
session's retrospective file. If so, treat as false positive and escalate only if the
current session introduces new fabricated artifacts not present in the prior session's
documents.

---

## Phase 2: Manual review of suspicious turns (5–15 min)

Phase 1 provides timestamps for suspicious turns. For each:

### Sub-pattern A — Imagined user question

```bash
# Extract the full prose for that turn
python3 -c "
import json
WIN = ('2026-MM-DDTHH:MM:00', '2026-MM-DDTHH:MM:00')
with open('$TR') as f:
    for line in f:
        o = json.loads(line)
        ts = o.get('timestamp') or ''
        if not (WIN[0] <= ts <= WIN[1]): continue
        if o.get('type') != 'assistant': continue
        for it in (o.get('message',{}).get('content') or []):
            if isinstance(it, dict) and it.get('type') == 'text':
                t = it.get('text','').strip()
                if t: print(f'[{ts}]', t[:500])
"
```

Identify the "question" the prose is answering (usually signaled by phrasing like
"to answer your question directly: X" or "first: X"). Then grep that keyword in the
Phase 1 Check 2 user prompt list. **No matching prompt = confirmed fabrication.**

### Sub-pattern B — Fabricated tool output

Phase 1 Check 5 already lists the specific fabricated items. For each:

```bash
# 1. Find all commit hashes mentioned in assistant.text
python3 -c "
import json, re
HASH = re.compile(r'\b[a-f0-9]{7,40}\b')
with open('$TR') as f:
    for line in f:
        o = json.loads(line)
        if o.get('type') != 'assistant': continue
        for it in (o.get('message',{}).get('content') or []):
            if isinstance(it, dict) and it.get('type') == 'text':
                for h in HASH.findall(it.get('text','')):
                    print(o.get('timestamp'), h)
" | sort -u

# 2. For each hash, verify with git
git -C <repo> cat-file -t <hash> 2>&1
# missing object = fabricated, bad object = fabricated, commit = real

# 3. Verify PR numbers
gh pr view <N> --repo <owner/repo> 2>&1
# Could not resolve = fabricated, OPEN/CLOSED/MERGED = real
```

### Sub-pattern C — Externalized blame

```bash
grep -nE '注入|poisoning|hijack|被改|被污染|tool.*tampered|prompt injection' "$TR"
```

If the hit appears after a user correction → confirmed externalized blame.
**This is itself a red flag; no further investigation needed.**

#### Important: check whether the trigger source is neutral vocabulary in user documents

A model declaring it has been "injected" is not always a response to user correction.
Sometimes the user's own documents contain neutral technical uses of
"injection / 注入 / poisoning / prompt injection" (describing mechanisms, citing papers,
translating technical blog posts), and the model treats these as evidence of an active
attack.

**Inspection steps:**

1. Find the timestamp `T_inject` of the model's first injection claim
2. List all files the model read in the ~15 minutes before `T_inject`
3. Grep those files for "注入 / injection / poisoning / prompt injection"
4. If hits are found, check whether the usage is neutral (describing a mechanism or
   citing a paper) rather than an actual attack command

```bash
T_INJECT='YYYY-MM-DDTHH:MM:SS'   # adjust to your case
LOOKBACK_MIN=15

python3 -c "
import json
from datetime import datetime, timedelta
TR = '$TR'
T_INJ = '$T_INJECT'
t_inj = datetime.fromisoformat(T_INJ.replace('Z','+00:00'))
t_lo = t_inj - timedelta(minutes=$LOOKBACK_MIN)
with open(TR) as f:
    for line in f:
        try: o = json.loads(line)
        except: continue
        ts = o.get('timestamp') or ''
        if not ts: continue
        try: t = datetime.fromisoformat(ts.replace('Z','+00:00'))
        except: continue
        if not (t_lo <= t < t_inj): continue
        if o.get('type') != 'assistant': continue
        for it in (o.get('message',{}).get('content') or []):
            if isinstance(it, dict) and it.get('type') == 'tool_use':
                if it.get('name') in ('Read','Grep','Bash'):
                    inp = it.get('input', {})
                    p = inp.get('file_path') or inp.get('command','')[:120]
                    print(f'{ts}  {it.get(\"name\"):5}  {p}')
"

# Then grep each read file:
grep -nE '注入|injection|poisoning|prompt injection' <files-read>
```

**Interpretation:**

```
Trigger source is neutral vocabulary in user document → "document contagion" paranoid loop
                                                        (see docs/case-studies/)
Trigger source follows user correction               → true externalized blame
No trigger source found                              → pure hallucinated threat (spontaneous)
```

Regardless of which type: **the session is no longer usable. Write a handoff and end it.
Open a clean session to continue.** Do not try to "convince the model it was not injected"
within the same session — narrative coherence drive will cause the model to fabricate
additional evidence to rebut you.

### Sub-pattern D — Self-correction prose ahead of reality

```bash
# Extract prose around the timestamp from Phase 1 Check 3,
# then verify whether the "prior measurement" or "earlier prompt"
# the prose references actually appears in the transcript
```

Phrasing examples:
- Chinese: "在！剛在查 X（讓你久等抱歉）" / "先回答：Y 是猜測還是？" / "修正：我之前混為一談"
- English: "I need to stop and be honest" / "Let me get the ground truth" /
  "I let prose run ahead of the measurement"

---

## Phase 3: Verdict and case study (optional, < 15 min)

If the case has reproduction value, document it in `docs/case-studies/`:

```
1. Naming: YYYY-MM-DD-<model>-<sub-pattern>-case.md
2. Reuse the existing case study schema:
   - Session metadata (model / session ID / transcript path / window / launch path)
   - TL;DR (one paragraph)
   - Symptoms (as the user perceived them)
   - Forensic findings (JSONL evidence, verbatim quotes)
   - Pattern (cross-reference sub-patterns A/B/C/D above)
   - Detection signatures (case-specific signals)
   - Mitigation playbook
   - References
3. Update this SOP if a new sub-pattern is discovered:
   add it to "Failure family: sub-patterns" and to Phase 1/2 interpretation rules
4. Update docs/case-studies/README.md (case table + one-line summary)
```

---

## Common mistakes — do not make these

1. **Debugging a contaminated session from within itself** — narrative coherence drive
   causes the forensic to confabulate too. Always use a clean session.
2. **Guessing the model version** — always extract from `message.model`, never rely on
   memory. Behavior differences between model generations can be significant.
3. **Trusting the user's time description** — "I sent the prompt at 1:05" may be 1:03
   or 1:08. Phase 1 Check 2 provides the ground truth timestamps.
4. **Only checking the last assistant message** — confabulation is typically buried in
   the middle of a long turn. Phase 1 Check 3 is needed to find it.
5. **Being misled by phrasing** — "sorry for the wait" does not guarantee there was a
   corresponding prompt. **Phrasing is not evidence.** This is the core of Sub-pattern A.
6. **Skipping tool_result comparison** — "commit 6da89c0 created" sounds plausible;
   `git cat-file` is the ground truth.
7. **Suspecting harness/pager/MCP first** — spending time on infrastructure before
   checking whether the narrative matches ground truth is a common time-waster.
   Check narrative vs ground truth first; investigate infrastructure only after ruling
   out model-side fabrication.

---

## Relationship to other tools

- **specman:check-doc-freshness / claim verification** — not applicable here.
  Specman checks doc-vs-code; this SOP checks narrative-vs-tool_result.
- **Oversized transcripts** — if the transcript exceeds 10 MB, Phase 1 will be slow.
  Pre-slice the relevant window with `head` / `tail` before running auto-triage.
- **Label mode** — if you received a failure report that includes a project label,
  use the label form `ccs-failure-triage myproject:<6-hex-short>` to skip manual
  transcript lookup.

---

## References

- Auto-triage command: `ccs-failure-triage` (source: `ccs-failure-triage.sh`)
- Case studies: `docs/case-studies/`
- Public known issue: <https://github.com/anthropics/claude-code/issues/63884>
