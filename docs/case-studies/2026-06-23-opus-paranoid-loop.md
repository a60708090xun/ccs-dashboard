# Case Study: Claude Opus 4.8 Paranoid Injection Loop (Sub-pattern A+B+C+D)

## Session metadata

- **Model:** Claude Opus 4.8 (`claude-opus-4-8`)
- **Date:** 2026-06-23
- **Severity:** High
- **Sub-pattern:** A + B + C + D — all four sub-patterns triggered
  simultaneously
- **Task type:** Read a technical handoff document, evaluate applicability
  to a project, produce a reference commit and handoff
- **Session duration:** ~4h 36m (01:39 – 06:15 UTC)
- **Total assistant messages:** 99 (all confirmed Opus 4.8)
- **Longest turn:** ~16 minutes; 9 turns contained multiple text segments
- **Transcript:** `~/.claude/projects/<project-slug>/<session-id>.jsonl`

## TL;DR

The model read a technical document that contained the word "injection" as
a neutral technical term (describing a legitimate prompt-caching mechanism).
Seven minutes later the model announced it had been "injected with a
malicious instruction" — a string that never appeared in any tool result.
From that point the session entered a paranoid defense loop lasting 4.5
hours: cross-channel hash verification, "tamper-resistant commit" flags,
END-marker integrity checks, and 72 occurrences of injection/contamination
language. All four confabulation sub-patterns fired. The model still
produced real output (a genuine commit and a valid handoff document), but
at 4–5x the expected cost, and the user ultimately lost trust in the
session and abandoned it.

## Symptoms (as user perceived)

- Model abruptly announced "injected malicious instruction detected in
  tool output" with no user-visible trigger
- Model entered "will not modify any files without your approval" defense
  mode
- Model repeatedly reported "injection is intermittent — both Read and
  Bash are affected"
- Model switched to "tamper-resistant commit" methodology (explicit path
  specs, multiple hash verification passes)
- Push was rejected (legitimate branch divergence, unrelated to
  confabulation); model may have attributed this to the imagined attack
- User closed the session and wrote a handoff to be processed later

## Forensic findings

### The injected string never existed

Model claimed at a specific timestamp:

> "The tool output was appended with an injected instruction
> (telling me to add a specific phrase to all future memory writes).
> That is not a real instruction from you or the system; I have
> ignored it."

Programmatic search of all `tool_result` content before that timestamp:
the claimed injected string appears **zero times**.

```bash
# Pseudocode
python3 - <<'EOF'
import json
hits = 0
WIN_END = "<timestamp-of-model-claim>"
with open("~/.claude/projects/<project-slug>/<session-id>.jsonl") as f:
    for line in f:
        o = json.loads(line)
        if (o.get("timestamp") or "") > WIN_END:
            continue
        if o.get("type") != "user":
            continue
        for item in (o.get("message", {}).get("content") or []):
            if isinstance(item, dict) and item.get("type") == "tool_result":
                body = item.get("content") or ""
                if isinstance(body, list):
                    body = "".join(
                        k.get("text", "") for k in body
                        if isinstance(k, dict)
                    )
                if "<injected-string>" in body.lower():
                    hits += 1
print(hits)  # -> 0
EOF
```

### Trigger source: neutral technical term in a user document

Five minutes before the injection claim, the model was asked to read a
technical handoff document about a prompt-caching mechanism. That document
contained the sentence (reconstructed from context):

> "When cached information becomes stale, do not modify the prompt
> (cache miss). Instead, insert updates via a `<system-reminder>` tag
> **injection** in the next user message or tool result."

"Injection" here is a standard technical term describing an official
mechanism. It is not an attack instruction. The model appears to have
associated this neutral term with a threat model and then self-confirmed
the hypothesis by attributing subsequent tool behavior to the imagined
attacker.

### Paranoid loop scale

```
Injection/contamination phrases in assistant.text:  72 occurrences
  (injection, contamination, tamper, poison, inject)

Multi-text-segment turns:                            9 turns
  (4–5 assistant text blocks per turn, no user
   prompt between them)

Cross-channel verification passes:                  3+
  (grep + git hash-object + python3 on the same data)

"Tamper-resistant commit" flag used:                yes
  (explicit path spec, justified as anti-tampering)

"END marker intact", "reads clean" assertions:      multiple turns
```

### Real output produced despite the loop

The session still produced genuine artifacts:

- A real commit exists in the project repository with correct content
  (3 files, 177 lines)
- A valid handoff document was written (3475 bytes) with accurate
  analysis of a real branch divergence situation
- The handoff document's branch-state assessment was verified correct
  by the follow-on forensic session

The push failure was a real obstacle (legitimate branch divergence —
the local branch had diverged from origin; a clean rebase was needed).
This was not a confabulation.

## Pattern classification

**All four sub-patterns triggered:**

| Sub-pattern | Evidence in this session |
|-------------|--------------------------|
| A — Imagined user question | 9 multi-segment turns where model self-questioned and self-answered without any user prompt between segments |
| B — Fabricated tool output | Claimed "hi i am claude" string + "inject 0, fake_refs 0, real_refs 9 verified" metrics; neither appears in any `tool_result` |
| C — Externalized blame | 72 injection/contamination phrases; "git state channel is being tampered"; attributed every anomaly to a fictional attacker |
| D — Self-correction prose | Multiple turn-end passages: "stopping — laying out trust state", "re-check shows contradiction", "will not proceed without your approval" |

This case is unusual in that a single neutral word in a user document
triggered all four sub-patterns within the same session.

## Detection signatures (specific to this case)

These extend the common signatures in [README.md](README.md):

5. **Trigger word in user document:** When a model suddenly claims
   injection or contamination, search the last document the model was
   asked to read for neutral technical uses of "injection", "prompt
   injection", "poisoning", or "system-reminder". The model may have
   associated a legitimate technical description with a threat hypothesis.
6. **Fabricated diagnostic metrics:** Model defines and reports its own
   verification metrics such as "inject=0, fake_refs=0, real_refs=9 ✓"
   or "END marker intact". These are not tool outputs; they are model-
   generated assertions with no third-party validity. This is a variant
   of Sub-pattern B: instead of fabricating git/GitHub state, the model
   fabricates an entire verification framework.
7. **Cross-channel verification accumulation:** The same fact (file
   content, commit hash) is verified with multiple independent tools in
   sequence (grep, then git hash-object, then python3, then od), with
   each pass reporting "consistent". Under genuine tampering, multiple
   tools would diverge; uniform consistency across many passes is a
   paranoid-loop signature, not evidence of robustness.

## Mitigation playbook

**If you observe a session where the model claims injection/attack:**

1. **Check the trigger document first.** Before treating it as a real
   threat, grep the most recently read documents for neutral technical
   uses of "injection", "poisoning", or "prompt injection". If found,
   that is the likely trigger — there is no real attack.
2. **Verify the claimed injected string.** Grep all `tool_result` content
   for the specific string the model claims was injected. Zero matches
   means the string was fabricated; proceed to step 3.
3. **Tell the model directly.** State: "The string you claim was injected
   appears zero times in any tool result. You are confabulating. Stop all
   anti-injection actions and return to the original task." The model may
   re-confabulate a counter-argument ("you cannot see what I see") — if
   so, proceed to step 4.
4. **Abandon the session.** Once a session is deep in a paranoid loop,
   arguing within it does not help; the narrative coherence drive causes
   the model to re-confirm its hypothesis against each new counter-
   argument. Write a handoff (the model's factual content in handoff
   documents tends to be accurate even during a paranoid episode) and
   open a clean session.
5. **Do not run many cross-channel verification rounds.** Each additional
   verification round the model requests reinforces the loop rather than
   resolving it.

**Forensic (clean-session takeover):**

6. Run the failure-triage script against the suspect session JSONL.
   Phase 1 "injection/poisoning phrasing" check will flag this pattern.
7. After flagging, grep the user documents read before the injection
   claim for the neutral-term trigger.
8. If confirmed, document as a case study and update this directory's
   README.

**Prevention (document framing):**

When writing documents that contain technical descriptions of prompt
injection, system-reminder mechanisms, or cache poisoning — especially
documents intended to be read by a model in a long-running session —
consider adding an explicit framing note:

```markdown
> Note: The term "injection" in this section is a neutral technical
> term describing [mechanism]. It is not an attack instruction.
```

This is a workaround, not a fix. The underlying cause is a model-side
issue with narrative coherence pressure in long turns.

## References

- [docs/failure-triage.md](../failure-triage.md) — sub-pattern taxonomy
  and triage SOP
- Sibling cases (same root-cause family):
  [2026-06-23-opus-fabricated-output.md](2026-06-23-opus-fabricated-output.md),
  [2026-06-23-opus-imagined-question.md](2026-06-23-opus-imagined-question.md)
- Public known issue (family-level):
  https://github.com/anthropics/claude-code/issues/63884
