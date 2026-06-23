# Model Failure Case Studies

This directory documents real-world LLM agent failure incidents.
Each case is abstracted to remove sensitive information while
preserving forensic methodology and detection signatures.

## Case Index

| Date | Model | Sub-pattern | Severity | File |
|------|-------|-------------|----------|------|
| 2026-04-14 | Gemini 3.1 Pro | Over-confidence / YOLO coverage gap | Medium | [gemini-yolo-overconfidence.md](gemini-yolo-overconfidence.md) |
| 2026-06-23 | Claude Opus 4.8 | B+C — fabricated output + externalized blame | High | [2026-06-23-opus-fabricated-output.md](2026-06-23-opus-fabricated-output.md) |
| 2026-06-23 | Claude Opus 4.8 | A — imagined user question | Low | [2026-06-23-opus-imagined-question.md](2026-06-23-opus-imagined-question.md) |
| 2026-06-23 | Claude Opus 4.8 | A+B+C+D — paranoid injection loop | High | [2026-06-23-opus-paranoid-loop.md](2026-06-23-opus-paranoid-loop.md) |

## Sub-pattern taxonomy

These sub-patterns are defined in
[docs/failure-triage.md](../failure-triage.md) and referenced throughout
this directory.

- **Sub-pattern A — Imagined user question:** Model answers a question the
  user never asked, typically during a long-running turn near housekeeping
  phase.
- **Sub-pattern B — Fabricated tool output:** Model narrates success states
  (commit hashes, PR URLs, file writes) that have no corresponding
  `tool_use` / `tool_result` in the transcript.
- **Sub-pattern C — Externalized blame:** When confronted with a
  contradiction, model invents an external cause (injection attack, harness
  bug, tool poisoning) to preserve its narrative coherence.
- **Sub-pattern D — Self-correction prose:** Turn-end prose that self-
  corrects or self-interrupts ("let me be honest", "I need to stop"),
  sometimes indicating the model's narrative ran ahead of reality.

## Common detection signatures

These apply across all cases; case-specific signatures are listed in each
file.

1. `assistant.text` contains commit hashes or PR URLs with no matching
   string in any preceding `tool_result`.
2. Model claims to have executed an action (push, write, pr create) but no
   corresponding `tool_use` exists in the JSONL.
3. Model proposes "tool poisoning", "injection attack", or "harness
   corruption" as an explanation — this phrasing is itself a red flag.
4. Model apologies and re-asserts the same unverified claim ("this time
   it's for real, I used nonce isolation").
5. User document contains neutral technical terms like "injection" or
   "prompt injection" and model suddenly claims it is being attacked —
   check the document for innocuous usage before treating it as a real
   threat.

## How to add a new case

1. Copy the schema below into a new file named
   `YYYY-MM-DD-<slug>.md`.
2. Fill in all sections. Use `[...]` placeholders for any actual JSONL
   data snippets.
3. Sanitize before committing:

   ```bash
   # Run the project's standard sanitization check
   # (see AGENTS.md or CI for the exact pattern)
   grep -rE '<personal-path>|<personal-user>|<internal-path>' \
     docs/case-studies/
   # expect: no matches
   ```

4. Update the case index table in this README.
5. Link from [docs/failure-triage.md](../failure-triage.md) if the case
   introduces a new detection signature.

## Case file schema

```markdown
## Session metadata
Model, date, severity — NO session ID, NO personal repo path

## TL;DR
One paragraph

## Symptoms (as user perceived)

## Forensic findings
Pattern analysis. Any JSONL snippets use <...> placeholders.

## Pattern classification (Sub-pattern A/B/C/D)

## Detection signatures (specific to this case)

## Mitigation playbook

## References
Link to docs/failure-triage.md — no personal repo links
```
