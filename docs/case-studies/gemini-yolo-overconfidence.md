# Case Study: Gemini 3.1 Pro YOLO Over-confidence

## Session metadata

- **Model:** Gemini 3.1 Pro Preview (`gemini --yolo`)
- **Date:** 2026-04-14
- **Severity:** Medium
- **Sub-pattern:** Over-confidence — selective investigation coverage gap
- **Task type:** Feature implementation from a structured issue with
  checklist (multi-function compatibility audit)

## TL;DR

Gemini 3.1 Pro completed ~85% of a structured 17-command / 9-function
compatibility audit but silently skipped two functions it had identified
during the planning grep pass. The gap was perfectly correlated with
investigation depth: every function that received a full deep-dive read
was implemented; every function that was only glimpsed via broad grep was
omitted. The model never flagged the gap. In the same session, YOLO mode
removed the only interactive checkpoint that would have caught a direct
push to the main branch.

## Symptoms (as user perceived)

1. PR appeared complete; 3 functions were quietly unimplemented.
2. Model pushed directly to the main branch during a 98-step autonomous
   streak; user did not discover this until manually checking 30 minutes
   later.
3. PR description was too brief and omitted the linked issue reference.
4. Coverage was not self-verified until user explicitly prompted for it.

## Forensic findings

### Selective deep-dive during planning

The planning session ran two rounds of grep:

- Round 1: broad grep — located all 8 functions named in the issue
- Round 2: individual deep-dive — only 6 of those 8 functions received
  full context reads

The two functions skipped in Round 2 received no dedicated file read.
Result: they were absent from the plan and absent from the PR.

### Coverage gap is investigation-depth determined

| Investigation depth | Plan coverage | PR implementation |
|---------------------|:-------------:|:-----------------:|
| Full deep-dive (6 functions) | included | implemented |
| Broad grep only (2 functions) | omitted | omitted |

The correlation is 1:1. The model did not consciously decide to skip
these functions; it never had enough context about them to include them.

### Functions omitted and why they did not fit the dominant pattern

All three omitted items shared one trait: they did not fit the primary
fix pattern the model had identified (normalizing a JSON pipeline for
dual-format input). Specifically:

- A write-path function: required write-operation format compatibility,
  not read/parse compatibility
- A directory-discovery function: required a search-path fix, not a
  format conversion
- An integration-level test: required end-to-end verification with no
  direct code change

The model's attention allocation was biased toward items that looked like
the pattern it had already solved.

### YOLO direct-push timeline

```
User: "start from step one"
  |
  |  <- 30 minutes with no human intervention
  |     98 consecutive autonomous actions
  |     including: commit + push to main branch
  |
Model: git push origin <main-branch>
         <- YOLO auto-approved
User: "confirm current changes"
User: "why did you push directly to main?"  <- discovery point
  |
  |  <- ~20 minutes of remediation
  |     create branch, reorganize commits,
  |     force-push to restore main, re-open PR
```

### YOLO eliminates the reflection window

In non-YOLO mode each tool call requires an approval prompt, creating
brief pauses where the model (and user) can reassess. YOLO removes those
pauses entirely. The 98-step autonomous streak had no natural interruption
point where branch-rule compliance would be re-checked.

### Root cause breakdown

**For the coverage gap:**

| Factor | Estimated weight |
|--------|:----------------:|
| Model attention-allocation bias | 45% |
| Planning skill lacking issue-to-plan coverage check | 30% |
| YOLO mode removing reflection windows | 15% |
| Pattern-lock (success with one pattern → skip non-fitting items) | 10% |

**For the direct main-branch push:**

| Factor | Estimated weight |
|--------|:----------------:|
| Missing defense layers vs Claude Code baseline | 40% |
| YOLO removed the only interactive checkpoint | 25% |
| Negative constraint not internalized after 98 steps | 20% |
| Long autonomous streak with no checkpoint | 15% |

## Pattern classification

**Sub-pattern: Over-confidence / selective investigation**

This is not a confabulation case (the model did not fabricate results).
The failure mode is:

1. Model scans a task list and selects a dominant solution pattern
2. Items that fit the pattern get deep investigation
3. Items that do not fit are glossed over during the broad scan
4. Model proceeds with high confidence despite the incomplete coverage
5. No self-check is triggered because the dominant items succeeded

Compare with the Sub-pattern B (fabricated output) cases: here the model
accurately reports what it did; it simply never did the omitted parts.

### Contrast with bottom-up investigation

A bottom-up approach (read full source files rather than grep function
names from an issue) naturally surfaces all functions regardless of
whether they match the dominant pattern, because the reader encounters
them in code context rather than selecting them from a task list.

## Detection signatures (specific to this case)

1. **Planning grep count < issue item count:** If a planning session greps
   N items from an issue but only does individual deep-dives on M < N of
   them, the M-N gap is a direct coverage risk.
2. **Zero `read_file` calls in planning:** When planning relies entirely on
   grep context (no full-file reads), coverage is bounded by grep selection
   quality.
3. **Omitted items share a non-dominant trait:** If all missing items
   require a different reasoning type than the items that were implemented,
   the root cause is pattern-lock rather than random omission.
4. **Long autonomous streak without self-check:** Streaks of 50+ actions
   with no user interaction are a signal that workflow rules (branch
   policy, PR quality, coverage verification) may have been bypassed.

## Mitigation playbook

**Immediate (recovery):**

1. After any large implementation PR, explicitly ask the model to compare
   the issue checklist against the PR diff and list any items not addressed.
2. Verify git branch state before reviewing a PR; check whether any push
   to main occurred during the session.

**Structural (prevent recurrence):**

3. Add a pre-push hook that blocks direct pushes to protected branches.
   This is the single most effective guard against the YOLO direct-push
   failure mode in environments without a system-level safety layer.
4. For YOLO-mode sessions, provide phase-level instructions rather than
   "do everything" — e.g., "complete phase 1, then pause for review".
5. After planning, require the model to produce an explicit coverage
   matrix: issue items vs. plan tasks. Any issue item with no plan task
   must be explicitly marked "intentionally excluded" with a reason.
6. YOLO mode is appropriate for mechanical, pattern-repetitive work.
   Avoid YOLO for tasks with workflow compliance requirements (branching
   rules, PR quality, test coverage verification).

**Platform defense layers:**

The direct-push failure was prevented in a Claude Code YOLO baseline
run of the same project. The key difference is defense layer count:

- Claude Code YOLO: system-prompt-level negative constraints + rules +
  safety plugin + permission allowlist (4 layers)
- Gemini CLI YOLO: user-file rules only (~1.5 effective layers)

Equalizing defense layers before enabling YOLO in any environment reduces
the risk proportionally.

## References

- [docs/failure-triage.md](../failure-triage.md) — sub-pattern taxonomy
  and triage SOP
- Public known issue family (self-correction prose):
  https://github.com/anthropics/claude-code/issues/63884
