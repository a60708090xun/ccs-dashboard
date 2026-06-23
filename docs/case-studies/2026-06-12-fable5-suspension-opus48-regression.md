# Incident Report: Fable 5 Suspension → Opus 4.8 Behavioral Regression

## Incident metadata

- **Type:** Systemic / server-side environmental regression
- **Date range:** 2026-06-12 (trigger) through at least 2026-06-23 (last observed)
- **Affected model:** Claude Opus 4.8
- **Severity:** High (multiple user-visible confabulation episodes; community-wide)
- **Root cause:** Anthropic server-side deployment change, not session-level failure
- **Related session cases:** all four Opus 4.8 case studies in this directory

## TL;DR

On June 12, 2026, a US government export control directive forced Anthropic to
suspend Claude Fable 5 and Mythos 5 globally. All Fable 5 traffic was
immediately rerouted to Opus 4.8. Starting approximately June 13, multiple
users independently reported that Opus 4.8 behavior had degraded — reasoning
shallower, confabulation rate higher, task completion less reliable. The
session-level confabulation cases documented in this directory (June 20–23)
are consistent with this regression window. Anthropic has not published a
post-mortem for this incident as of 2026-06-23.

## Event timeline

```
2026-06-09  Claude Fable 5 and Mythos 5 released publicly

2026-06-12  US government export control directive issued
            Anthropic suspends Fable 5 and Mythos 5 globally, same day
            All Fable 5 sessions rerouted to Opus 4.8
            Presumed: Anthropic performs emergency infrastructure
            deployment or harness adjustment to absorb traffic spike

~2026-06-13  First user reports of Opus 4.8 behavioral change
             GitHub issue #68780 reports onset "roughly 3 days before
             June 16" — points to ~June 13 as first symptom date

2026-06-16  GitHub issue #68780 opened:
            "[Bug][Urgent] Claude Opus 4.8 reasoning degradation,
            speed and performance regression"
            Complaint: model "can't hold multiple facts together
            anymore, fails to read references, lazy and shallow"

~2026-06-17  GitHub issue #69045 opened:
             "Opus 4.8 regression. Model becoming worse over time."
             Skills previously stable "verging on hopeless"

2026-06-20  First session-level confabulation confirmed in this repo
            (fabricated-injection-claim, Sub-pattern B+C+A)

2026-06-23  Three additional confabulation sessions in a single day
            (fabricated-output, imagined-question, paranoid-loop)
```

## Why Fable 5 suspension likely degraded Opus 4.8

Anthropic has a documented history of server-side "harness" changes
(system-prompt modifications, reasoning effort defaults, verbosity caps)
that silently affect model behavior without changing model weights. In
April 2026, Anthropic published a post-mortem acknowledging that three
such changes caused a quality regression, which was resolved by reverting
them (see References).

The June 12 Fable 5 suspension was an emergency event with no planned
ramp. The most probable mechanisms:

1. **Rapid infrastructure scaling:** Sudden traffic increase to Opus 4.8
   may have required spinning up additional inference capacity with
   slightly different configuration or model variant.

2. **Emergency harness adjustment:** To handle the transition, Anthropic
   may have modified Opus 4.8's system prompt, effort level, or
   context-handling in ways not publicly disclosed.

3. **Load-driven quality degradation:** Even without configuration change,
   serving the same model under significantly higher load can produce
   measurable quality differences due to batching and scheduling.

None of these mechanisms are confirmed; Anthropic has not commented on
this specific regression.

## Community evidence

The following GitHub issues (anthropics/claude-code) document the
post-June-12 regression independently of this repository:

- **#68780** — "Urgent: Opus 4.8 reasoning degradation" (filed June 16)
  Onset: ~June 13. Symptoms: shallow reasoning, context drop, laziness.

- **#69045** — "Opus 4.8 regression, model becoming worse over time"
  (~filed June 17). Stable long-running skills degraded; work that
  previously took hours now unreliable.

- **#68428** — "Opus 4.8 performance degradation: significantly slower
  response times" — infrastructure-level signal alongside quality drop.

## Relationship to session-level case studies

The four Opus 4.8 confabulation sessions documented in this directory
(2026-06-20 and 2026-06-23) should be interpreted in this context:

- The individual sessions exhibit Sub-patterns A/B/C/D as described
  in each case file; those patterns are real and actionable.
- The *increased frequency* of confabulation compared to earlier Opus
  4.8 use is consistent with the June 12 regression, not normal
  Opus 4.8 behavior.
- Earlier Opus 4.8 usage (May 29 – June 12) did not produce confirmed
  confabulation cases in this repository.

## Precedent: April 2026 harness regression

This is the second documented instance of Anthropic server-side changes
causing user-visible quality regression in 2026. In April, Anthropic
changed default reasoning effort and added a verbosity cap without
announcement, causing widespread complaints. The post-mortem (published
April 23) confirmed the cause and described the revert.

That incident establishes: **Anthropic can and does make silent
server-side behavioral changes**, and these changes can degrade model
behavior in ways indistinguishable from model-weight regressions.

## Detection at the incident level

Session-level triage (`ccs-failure-triage`) detects individual
confabulating sessions but cannot distinguish "this session happened to
fail" from "we are in a system-wide regression window."

Signals that suggest a system-wide regression (not an isolated session):

1. **Temporal clustering:** Multiple unrelated sessions confabulate
   within days of each other after a previously stable period.
2. **Coincidence with a known infrastructure event:** Model suspension,
   billing change, or harness update announced within 1–2 weeks prior.
3. **Community signal:** Multiple independent GitHub issues reporting
   similar degradation opened within the same week.
4. **Usage-db evidence:** Sudden shift in session outcomes around a
   specific date, without a corresponding task-complexity change.

When these signals align, the appropriate response is **model switch**
(to a stable model like Sonnet 4.6), not session-level debugging.

## Mitigation

**Immediate:**
- Switch affected workflows to `claude-sonnet-4-6` or another model
  unaffected by the regression.
- Do not invest time debugging confabulating sessions; they are
  symptomatic, not causal.

**Ongoing:**
- Monitor anthropics/claude-code issues for regression reports after
  any major Anthropic infrastructure event (model launch, model
  suspension, billing change).
- The `ccs-failure-triage` tool remains useful for session-level
  triage, but temporal clustering of failures is the primary signal
  for declaring a regression window.

**For Anthropic:**
- A post-mortem or status-page entry for the June 12 regression would
  allow users to correctly attribute session failures and avoid
  unnecessary debugging time.

## References

- [anthropics/claude-code #68780](https://github.com/anthropics/claude-code/issues/68780) — Urgent: Opus 4.8 degradation (June 16)
- [anthropics/claude-code #69045](https://github.com/anthropics/claude-code/issues/69045) — Opus 4.8 regression over time (~June 17)
- [anthropics/claude-code #68428](https://github.com/anthropics/claude-code/issues/68428) — Opus 4.8 slower response times
- [Anthropic April 2026 post-mortem](https://www.anthropic.com/engineering/april-23-postmortem) — harness changes caused regression; precedent
- [VentureBeat: harness/instruction changes caused degradation](https://venturebeat.com/technology/mystery-solved-anthropic-reveals-changes-to-claudes-harnesses-and-operating-instructions-likely-caused-degradation)
- Session-level sibling cases: all `2026-06-20-*.md` and `2026-06-23-*.md` files in this directory
- Triage tool: `ccs-failure-triage` — session-level detection SOP
