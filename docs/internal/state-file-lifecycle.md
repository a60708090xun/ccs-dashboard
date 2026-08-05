# Dispatch state-file lifecycle

> **Why this exists:** the dispatch subsystem coordinates across layers via
> files on disk, not in-memory IPC. `jobs.jsonl` in particular is
> **append-only with last-write-wins merge** — a job's "current" record is
> reconstructed, not stored — which is non-obvious and easy to break. This
> doc is the committed reference for what each dispatch file is, who writes
> it, and how it transitions.
>
> **When to read:** before changing how a job record is written or read
> (`_ccs_dispatch_jsonl_*`, `_ccs_dispatch_finish*`), the result/evidence
> layout, the cleanup policy, or the worker completion signal. The code
> owns the exact schema; this doc records the lifecycle and cites the
> functions. Companion: [`architecture-invariants.md`](architecture-invariants.md).
>
> **This repo is public** — no personal paths / hostnames / credentials
> here. Paths below are relative to the dispatch data dir
> (`_ccs_dispatch_dir`, itself under `_ccs_data_dir`); the absolute location
> is environment-derived, not hardcoded.

## 1. File inventory

| Path (under dispatch dir) | Writer | Reader | Persistence |
|---|---|---|---|
| `jobs.jsonl` | `_ccs_dispatch_jsonl_append` (dispatch + each finalize + fallback + chain hop) | `_ccs_dispatch_jsonl_latest`, `ccs-jobs` | permanent (append-only) |
| `results/<job_id>.md` | `_ccs_dispatch_finish` / `_ccs_dispatch_finish_agentpager` | `ccs-jobs <id>`, operator | TTL (`CCS_DISPATCH_RESULT_TTL_DAYS`, default 7) |
| `results/<job_id>.raw` | worker stdout capture | `_ccs_dispatch_finish` (folds into `.md`) | transient — removed once `.md` is built; else pruned after 60 min |
| `results/<job_id>.err` | worker stderr capture | `_ccs_dispatch_finish` (folds into `.md`) | kept for debugging (TTL) |
| `results/<job_id>.prompt` | dispatch (pre-spawn) | `_ccs_dispatch_finish` (Task field, first 200 chars) | transient — removed at finish; else pruned after 60 min |
| `results/<job_id>.handoff` | `_ccs_dispatch_finish_agentpager` (captured worker handoff) | `ccs-jobs`, chain bridge | TTL |
| `pids/<job_id>.pid` | async spawn (`nohup` monitor pid) | `_ccs_dispatch_running_count`, `_ccs_dispatch_lazy_cleanup` | removed at finish / when pid dead |
| `runs/<id>-chain-NN/` | gate path (`_ccs_dispatch_run`) | operator, review | permanent (evidence tree) |
| `<project>/tmp/handoff-<job_id>.md` | the **worker** (in its own repo) | monitor (completion signal) | worker-owned; not in dispatch dir |

## 2. jobs.jsonl — append-only, last-write-wins merge

The central invariant: **`jobs.jsonl` is never edited in place.** Every
state change appends a new JSON line keyed by `job_id`.
`_ccs_dispatch_jsonl_latest` reconstructs the current record with
`reduce .[] as $r ({}; . + $r)` — all records for that `job_id` merged in
file order, later fields overriding earlier ones.

Consequence: a partial record is legal. A finalize line carrying only
`{job_id, status, finished_at, summary}` merges onto the initial record's
`{project, backend, created_at, ...}` to form the complete view. Any reader
MUST go through `_ccs_dispatch_jsonl_latest`, never read a single line.

### Record lifecycle for one job

```
1. dispatch (ccs-dispatch)          append: full initial record, status="running"
   ├─ context_injected, mode, backend, cli, created_at
   ├─ if --chain:  chain=true, chain_depth=0, chain_max
   └─ if wake-eligible: wake_slot   (resolvable slot AND backend==agentpager)

2. (optional) fallback correction   append: {backend:<actual>, cli:"claude", fallback:true}
   └─ only when _CCS_DISPATCH_LAST_BACKEND != resolved backend (I2/I3)
      — a later line overrides backend/cli via the reduce-merge

3. finalize                         append: terminal status + finished_at + summary
   ├─ headless (_ccs_dispatch_finish):        + exit_code
   └─ agentpager (_ccs_dispatch_finish_agentpager): + handoff (bool)
```

### Status vocabulary

| Status | Set by | Meaning |
|---|---|---|
| `running` | dispatch (initial) + chain-hop lineage | dispatched, not yet finalized |
| `completed` | headless exit 0; agentpager no-handoff default | finished, success |
| `timeout` | headless exit 124 | wall-clock timeout (headless only; see I8) |
| `failed` | headless other exit; agentpager worker gone; chain next-hop launch failure | finished, failure |
| `handoff-ready` | agentpager worker wrote + capture succeeded | worker signalled done via handoff file |

`exit_code → status` mapping lives in `_ccs_dispatch_finish` (0→completed,
124→timeout, *→failed). `handoff-ready` vs the no-handoff default is decided
in `_ccs_dispatch_finish_agentpager` (see I8 — a captured handoff file is
the completion signal).

Note: a chain *stopping* (non-PASS / depth / cycle / next-load failure) does
not overwrite a hop's `status`; it records a separate `chain_stopped` field
on the record (`_ccs_dispatch_chain_next`). The gate-path chain driver
(`_ccs_dispatch_run`) writes nothing to `jobs.jsonl` at all — its evidence
lives only under `runs/` (§4).

## 3. Per-job result files

`_ccs_dispatch_finish` builds `results/<job_id>.md` — a structured summary
(Project / Task / Status / Exit code / Backend / Created / Finished /
Duration, then `## Output` from `.raw` and `## Errors` from `.err`). It then
appends the finalize line, and cleans up: the `.raw` is removed once folded
into `.md`, the `.prompt` is removed, the `.pid` is removed; `.err` is kept
for debugging.

`ccs-jobs <id>` reads the merged record for the board line; the full `.md`
stays on disk and is read on demand (context economy — the board carries a
thin pointer, not the transcript).

## 4. runs/ — gate evidence tree (gate path only)

`ccs-dispatch-run` writes a per-chain evidence tree under `runs/`
(`_ccs_dispatch_chain_alloc_dir` allocates `<first_id>-chain-NN`):

```
runs/<first_id>-chain-NN/
├── chain.json                     # chain-level summary (hops[], stop_reason, outcome, depth)
└── hop-NN-<task_id>/
    ├── task.yaml                  # frozen at dispatch (AC immutable — §1 of the gate)
    ├── base-commit                # cwd HEAD before attempt 1 — the diff anchor
    ├── attempt-NN/
    │   ├── prompt.md              # attempt 1 = goal; ≥2 = §6 feedback + goal
    │   ├── executor-output.md     # worker stdout+stderr
    │   ├── executor-exit-code     # worker rc, headless backend only (evidence)
    │   ├── worker-error           # deterministic infra failure class, if any
    │   ├── git-status.txt         # ground-truth porcelain
    │   ├── diff.patch             # ground-truth diff
    │   └── gate/<ac-id>.json      # per-AC verdict evidence
    └── final.json                 # {outcome, attempts, worker_rc, escalation}
```

`task.yaml` is frozen on entry — acceptance criteria must not change
mid-run. The gate re-derives ground truth (`git-status.txt` / `diff.patch`)
independently of the worker's self-report (see I4). `diff.patch` is taken
against `base-commit`, not against the index: a worker is free to stage or
commit its own edits, and a bare `git diff` would then be empty — making "did
nothing" and "did the work and staged it" identical in the evidence tree.

Two limits of the anchor. It is per-hop, so in a chain whose earlier hop left
its edits uncommitted, a later hop's `diff.patch` also carries them (the bare
`git diff` behaved the same way; this is not new). And when no anchor can be
resolved — `cwd` is not a git repo, has no commit yet, or the recorded revision
no longer exists — capture falls back to the bare `git diff`, where a staged
edit is again invisible and `git-status.txt` is the reliable material.

`worker-error` exists only when the worker demonstrably never ran to
completion and a retry cannot change that (`exit-125` / `exit-126` /
`exit-127`, `agentpager-daemon-down`, `agentpager-no-proj-map`). Failures
that a retry might survive — a timeout, a plain non-zero rc, an occupied
agentpager seat, a launch file that could not be written — deliberately
do not write it. It is the gate's ERROR input; its class is copied into
`gate/verdict.json.worker_error`, and `final.json` carries the last
attempt's `worker_rc` plus `escalation.reason` (`gate` | `worker_error`,
read back from that verdict) so a reader can separate "judged failed"
from "never finished" without opening the trace. `worker_rc` comes from
`executor-exit-code`, which only the headless seam writes — under
`backend: agentpager` it is always `null` and `agentpager-wait-rc` is the
corresponding signal.

## 5. Cleanup

`_ccs_dispatch_lazy_cleanup` (best-effort, on dispatch calls):

- deletes `results/*` older than `CCS_DISPATCH_RESULT_TTL_DAYS` (default 7);
- prunes `pids/*.pid` whose process is dead (`kill -0`);
- deletes stray `results/*.raw` / `*.prompt` older than 60 min (transient
  files a crashed run left behind before `_ccs_dispatch_finish` could).

`_ccs_dispatch_running_count` counts live pidfiles and warns past
`CCS_DISPATCH_MAX_CONCURRENT_WARN` (default 3).

## 6. Worker completion signal

The async agent-pager worker signals completion by writing
`tmp/handoff-<job_id>.md` **in its own project repo** (not the dispatch
dir). `_ccs_dispatch_agentpager_prompt` injects a non-negotiable handoff
rule instructing the worker to write that exact path last, with a YAML
frontmatter block (`summary` / `outcome` / `next`) the dispatcher parses
for the board. The monitor (`_ccs_dispatch_agentpager_monitor`) polls for
this file; on appearance it stops the seat and finalizes, capturing the
file to `results/<job_id>.handoff`. There is no wall-clock kill on this
path (design D2 — see I8).

## How to update

1. Change the code first; this doc follows the code, not the reverse.
2. Update the § 1 inventory row and, if a status or record-shape changed,
   § 2. Keep cites as **function names** + `tests/test-*.sh`.
3. Test backstops: `tests/test-dispatch.sh`, `tests/test-jobs-agentpager.sh`,
   `tests/test-dispatch-chain.sh`, `tests/test-handoff.sh`.
