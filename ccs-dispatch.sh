#!/usr/bin/env bash
# ccs-dispatch.sh — Session dispatch: ccs-dispatch + ccs-jobs + ccs-dispatch-run (review gate + gated task chain)
# Sourced by ccs-dashboard.sh

# ── Configurable parameters ──
CCS_DISPATCH_SYNC_TIMEOUT="${CCS_DISPATCH_SYNC_TIMEOUT:-120}"
CCS_DISPATCH_TIMEOUT="${CCS_DISPATCH_TIMEOUT:-600}"
CCS_DISPATCH_JOBS_LIMIT="${CCS_DISPATCH_JOBS_LIMIT:-20}"
CCS_DISPATCH_TASK_DISPLAY_LEN="${CCS_DISPATCH_TASK_DISPLAY_LEN:-60}"
CCS_DISPATCH_RESULT_TTL_DAYS="${CCS_DISPATCH_RESULT_TTL_DAYS:-7}"
CCS_DISPATCH_SUMMARY_LINES="${CCS_DISPATCH_SUMMARY_LINES:-30}"
CCS_DISPATCH_SUMMARY_MAX_CHARS="${CCS_DISPATCH_SUMMARY_MAX_CHARS:-200}"
CCS_DISPATCH_MAX_CONCURRENT_WARN="${CCS_DISPATCH_MAX_CONCURRENT_WARN:-3}"
CCS_DISPATCH_CHAIN_MAX_DEPTH="${CCS_DISPATCH_CHAIN_MAX_DEPTH:-5}"
CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS="${CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS:-4000}"
CCS_DISPATCH_GATE_LOOP_BUDGET="${CCS_DISPATCH_GATE_LOOP_BUDGET:-1}"
CCS_DISPATCH_GATE_CMD_TAIL_CHARS="${CCS_DISPATCH_GATE_CMD_TAIL_CHARS:-2000}"

# ── Backend selection ──
# Returns 0 if the agent-pager backend is usable, 1 otherwise.
# Requires the daemon active and the local-channel spool present, then
# applies Hybrid Detection (design Decision A):
#   same-uid  — spool owned by the caller (personal workflow): the caller
#               already has full access, so skip the claude-broker group
#               and setgid checks; daemon + inbound/ is enough.
#   cross-uid — spool owned by another user (shared seat): enforce the
#               strict AVer checks — caller in the claude-broker group and
#               the inbound spool carrying that group (setgid evidence).
_ccs_dispatch_agentpager_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user is-active --quiet agent-pager.service 2>/dev/null || return 1
  local pager_dir="${AGENT_PAGER_DIR:-$HOME/.agent-pager}"
  [ -d "$pager_dir" ] || return 1
  [ -d "$pager_dir/inbound" ] || return 1

  # same-uid personal workflow: caller owns the spool -> trust it.
  [ "$(stat -c %u "$pager_dir" 2>/dev/null)" = "$(id -u)" ] && return 0

  # cross-uid shared seat: strict group + setgid verification.
  id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx claude-broker || return 1
  [ "$(stat -c %G "$pager_dir/inbound" 2>/dev/null)" = "claude-broker" ] || return 1
  return 0
}

# Echoes the backend to use: "headless" or "agentpager".
# CCS_DISPATCH_BACKEND: auto (default) | agentpager | headless.
_ccs_dispatch_resolve_backend() {
  local choice="${CCS_DISPATCH_BACKEND:-auto}"
  case "$choice" in
    headless|agentpager) printf '%s\n' "$choice" ;;
    auto)
      if _ccs_dispatch_agentpager_available; then
        printf 'agentpager\n'
      else
        printf 'headless\n'
      fi ;;
    *) printf 'headless\n' ;;
  esac
}

# ── Data directory ──
_ccs_dispatch_dir() {
  local dir
  dir="$(_ccs_data_dir)/dispatch"
  mkdir -p "$dir/results" "$dir/pids"
  echo "$dir"
}

# ── Review gate (Stage 1): task.yaml + acceptance-criteria verification ──
# See docs/commands.md § ccs-dispatch-run. Scope C: gate + single retry, no
# tier ladder, no chain wiring, no Stage-2 automation.

# Parse a task.yaml into compact JSON (python+pyyaml -> jq). Validates: id and
# goal are non-empty strings; acceptance_criteria is a non-empty array; each AC
# has a string id and EXACTLY ONE of verify.cmd / verify.guidance. Echoes the
# JSON; rc 1 (+ stderr) on a missing file, parse error, or validation failure.
_ccs_dispatch_gate_load_task() {
  local yaml="$1"
  [ -f "$yaml" ] || { echo "gate: task file not found: $yaml" >&2; return 1; }
  local js
  js="$(python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])) or {}, sys.stdout)' "$yaml" 2>/dev/null)" \
    || { echo "gate: task YAML parse failed: $yaml" >&2; return 1; }
  # Validation: id/goal non-empty strings; non-empty AC array; each AC id is a
  # filesystem-safe token (used verbatim as gate/<id>.json) and unique; each AC
  # has exactly one of cmd/guidance; and at least one cmd-track AC exists (an
  # all-guidance task would auto-PASS with zero deterministic verification,
  # defeating the gate's purpose).
  echo "$js" | jq -e '
    (.id | type == "string" and (length > 0))
    and (.goal | type == "string" and (length > 0))
    and (.acceptance_criteria | type == "array" and (length > 0))
    and (all(.acceptance_criteria[];
      (.id | type == "string" and test("^[A-Za-z0-9_.-]+$"))
      and (([.verify.cmd, .verify.guidance]
            | map(select(. != null and . != "")) | length) == 1)))
    and (([.acceptance_criteria[].id] | length) ==
         ([.acceptance_criteria[].id] | unique | length))
    and (any(.acceptance_criteria[]; (.verify.cmd // "") != ""))
    and ((.next == null) or (.next | type == "string" and (length > 0)))
    and ((.executor == null) or
         (.executor | type == "string" and (. == "claude" or . == "gemini")))
  ' >/dev/null 2>&1 \
    || { echo "gate: task validation failed: $yaml" >&2; return 1; }
  echo "$js"
}

# Deterministically expand a chain-spec YAML into per-hop task.yaml files in
# <dest_dir>. Merges spec.defaults into each hop (hop keys override), wires next:
# in hops order (last hop has none), names files hop-NN-<id>.task.yaml. Echoes the
# entry filename (basename of hop-01). rc 1 on unparseable spec / no hops / hop
# missing id. Does NOT validate AC/executor -- that is delegated to load_task by the
# caller. python3+pyyaml here so emitted YAML round-trips through load_task's parser.
_ccs_dispatch_plan_expand() {
  local spec="$1" dest="$2"
  [ -f "$spec" ] || { echo "plan: spec not found: $spec" >&2; return 1; }
  mkdir -p "$dest" || return 1
  python3 - "$spec" "$dest" <<'PY'
import sys, os, re, yaml
spec_path, dest = sys.argv[1], sys.argv[2]
try:
    spec = yaml.safe_load(open(spec_path)) or {}
except Exception as e:
    sys.stderr.write("plan: spec YAML parse failed: %s\n" % e); sys.exit(1)
defaults = spec.get("defaults") or {}
hops = spec.get("hops")
if not isinstance(hops, list) or not hops:
    sys.stderr.write("plan: spec has no non-empty 'hops' list\n"); sys.exit(1)
# precompute filenames (need next hop's name for next: wiring). hop id becomes a
# filename, so require the same token set the gate enforces on AC ids.
names = []
for i, hop in enumerate(hops):
    if not isinstance(hop, dict):
        sys.stderr.write("plan: hop %d is not a mapping\n" % (i + 1)); sys.exit(1)
    hid = hop.get("id")
    if not isinstance(hid, str) or not re.match(r"^[A-Za-z0-9_.-]+$", hid):
        sys.stderr.write("plan: hop %d has missing or invalid 'id' "
                         "(need ^[A-Za-z0-9_.-]+$)\n" % (i + 1)); sys.exit(1)
    names.append("hop-%02d-%s.task.yaml" % (i + 1, hid))
for i, hop in enumerate(hops):
    merged = dict(defaults)      # shallow: hop keys override defaults keys
    merged.update(hop)
    if i + 1 < len(hops):
        merged["next"] = names[i + 1]
    else:
        merged.pop("next", None)
    with open(os.path.join(dest, names[i]), "w") as f:
        yaml.safe_dump(merged, f, sort_keys=True, default_flow_style=False)
sys.stdout.write(names[0])
PY
}

# Expand a chain-spec into <out_dir> ONLY if every emitted hop passes the gate's
# own task loader (reusing _ccs_dispatch_gate_load_task = the single source of
# validation truth: >=1 AC, >=1 cmd-track AC, executor whitelist, next: type,
# unique AC ids). Atomic: expand to a staging dir, validate all, move into place
# on full success; on any failure remove staging and leave <out_dir> untouched.
# Echoes the absolute entry task path on success.
_ccs_dispatch_plan_generate() {
  local spec="$1" out="$2"
  local stage="${out%/}.staging.$$"
  rm -rf "$stage"
  local entry
  entry="$(_ccs_dispatch_plan_expand "$spec" "$stage")" || { rm -rf "$stage"; return 1; }
  local f
  for f in "$stage"/hop-*.task.yaml; do
    if ! _ccs_dispatch_gate_load_task "$f" >/dev/null 2>&1; then
      echo "plan: generated task failed gate validation: $(basename "$f")" >&2
      rm -rf "$stage"; return 1
    fi
  done
  mkdir -p "$out" || { rm -rf "$stage"; return 1; }
  # Refresh: drop hop-*.task.yaml from a prior generation so a shorter/renamed
  # chain does not leave orphan hops behind (only our own pattern; unrelated
  # files in <out> are left alone). Validation already passed, so this is safe.
  rm -f "$out"/hop-*.task.yaml
  mv "$stage"/hop-*.task.yaml "$out"/ || { rm -rf "$stage"; return 1; }
  rm -rf "$stage"
  echo "$(_ccs_dispatch_abspath "$out/$entry")"
}

# Run one acceptance criterion against ground truth. cmd track: `bash -c <cmd>`
# with cwd=<cwd>, bounded by <timeout_sec> (0 = unbounded), exit 0 = PASS /
# non-zero = FAIL (a timeout returns 124 -> FAIL). guidance track: no execution,
# verdict SKIPPED_FOR_LLM (Stage 2 fills it later). Echoes the §4.1 AC record.
# The stderr scratch file lives OUTSIDE <cwd> so it never perturbs an AC that
# inspects the repo's own working tree (e.g. a clean-tree check).
_ccs_dispatch_gate_run_ac() {
  local cwd="$1" ac="$2" timeout_sec="${3:-0}"
  local id cmd guidance
  id="$(echo "$ac" | jq -r '.id')"
  cmd="$(echo "$ac" | jq -r '.verify.cmd // empty')"
  guidance="$(echo "$ac" | jq -r '.verify.guidance // empty')"

  if [ -n "$guidance" ]; then
    jq -n --arg id "$id" \
      '{ac_id:$id, track:"guidance", cmd:null, verdict:"SKIPPED_FOR_LLM",
        exit_code:null, stdout_tail:"", stderr_tail:"", duration_ms:null,
        na_reason:null, stage2_note:null}'
    return 0
  fi

  local t0 t1 dur out err rc verdict errfile to=""
  case "$timeout_sec" in ''|*[!0-9]*) timeout_sec=0 ;; esac
  [ "$timeout_sec" -gt 0 ] && to="timeout $timeout_sec"
  errfile="$(_ccs_dispatch_dir)/.gate-ac-err.$$.${id}"
  t0="$(date +%s%N)"
  out="$( (cd "$cwd" && $to bash -c "$cmd") 2> "$errfile" )"; rc=$?
  err="$(cat "$errfile" 2>/dev/null)"; rm -f "$errfile"
  t1="$(date +%s%N)"
  dur=$(( (t1 - t0) / 1000000 ))
  [ "$rc" -eq 0 ] && verdict="PASS" || verdict="FAIL"

  jq -n --arg id "$id" --arg cmd "$cmd" --arg v "$verdict" \
    --argjson ec "$rc" --argjson dur "$dur" \
    --arg so "$(printf '%s' "$out" | tail -c "$CCS_DISPATCH_GATE_CMD_TAIL_CHARS")" \
    --arg se "$(printf '%s' "$err" | tail -c "$CCS_DISPATCH_GATE_CMD_TAIL_CHARS")" \
    '{ac_id:$id, track:"cmd", cmd:$cmd, verdict:$v, exit_code:$ec,
      stdout_tail:$so, stderr_tail:$se, duration_ms:$dur,
      na_reason:null, stage2_note:null}'
}

# Pure gate verdict (scope C: no tier ladder). Input: JSON array of
# {ac_id,track,verdict}. Rules (§3.2/§3.3): any HARD_STOP -> HARD_STOP; else any
# ERROR -> ESCALATE (no budget consumed); else any FAIL -> RETRY if
# attempt<=budget else ESCALATE; else PASS (guidance SKIPPED_FOR_LLM ignored).
# Echoes §4.2 JSON with timestamp:null (caller stamps it). No side effects.
_ccs_dispatch_gate_verdict() {
  local acs="$1" attempt="$2" budget="$3"
  local remaining=$(( budget - attempt ))
  [ "$remaining" -lt 0 ] && remaining=0
  echo "$acs" | jq \
    --argjson attempt "$attempt" --argjson budget "$budget" \
    --argjson remaining "$remaining" '
    ([.[] | select(.verdict=="FAIL") | .ac_id]) as $failed
    | (any(.[]; .verdict=="HARD_STOP")) as $hard
    | (any(.[]; .verdict=="ERROR")) as $err
    | (($failed|length) > 0) as $anyfail
    | (if $hard then "HARD_STOP"
       elif $err then "ESCALATE"
       elif $anyfail then (if $attempt <= $budget then "RETRY" else "ESCALATE" end)
       else "PASS" end) as $verdict
    | {verdict:$verdict, attempt:$attempt, failed_acs:$failed,
       loop_budget_remaining:$remaining,
       next_executor:{cli:"", reason:"same_executor_no_tier_ladder"},
       timestamp:null}
  '
}

# Run the full gate for one attempt: execute each AC against <cwd>, write per-AC
# evidence to <attempt_dir>/gate/AC<n>.json, compute + stamp the gate verdict to
# <attempt_dir>/gate/verdict.json. Echoes the verdict string for the caller to
# branch on. The sole writer of the gate/ evidence dir (§5).
_ccs_dispatch_gate_run() {
  local cwd="$1" task="$2" attempt_dir="$3" attempt="$4" budget="$5"
  local gate_dir="$attempt_dir/gate"
  mkdir -p "$gate_dir"

  local timeout_sec
  timeout_sec="$(echo "$task" | jq -r '.execution_policy.timeout_sec // empty')"
  [ -z "$timeout_sec" ] && timeout_sec="$CCS_DISPATCH_TIMEOUT"

  local n verdicts='[]' ac rec ac_id
  n="$(echo "$task" | jq '.acceptance_criteria | length')"
  local i=0
  while [ "$i" -lt "$n" ]; do
    ac="$(echo "$task" | jq -c ".acceptance_criteria[$i]")"
    rec="$(_ccs_dispatch_gate_run_ac "$cwd" "$ac" "$timeout_sec")"
    ac_id="$(echo "$rec" | jq -r '.ac_id')"
    echo "$rec" | jq '.' > "$gate_dir/${ac_id}.json"
    verdicts="$(jq -n --argjson a "$verdicts" --argjson r "$rec" \
      '$a + [{ac_id:$r.ac_id, track:$r.track, verdict:$r.verdict}]')"
    i=$((i + 1))
  done

  local verdict_json
  verdict_json="$(_ccs_dispatch_gate_verdict "$verdicts" "$attempt" "$budget" \
    | jq --arg ts "$(date -Iseconds)" '.timestamp = $ts')"
  echo "$verdict_json" > "$gate_dir/verdict.json"
  echo "$verdict_json" | jq -r '.verdict'
}

# Build the §6 retry failure summary from a completed attempt's gate evidence.
# Machine facts only (AC id + cmd + exit code); never worker prose, to avoid
# polluting the next attempt's fresh context. Empty output if no cmd-AC FAILed.
_ccs_dispatch_gate_feedback() {
  local attempt_dir="$1" attempt="$2"
  # Iterate every per-AC evidence file (any id, not just AC*), skipping the gate
  # verdict summary. AC ids are validated to a filesystem-safe token by the
  # loader, so <id>.json is a stable 1:1 mapping.
  local gate_dir="$attempt_dir/gate" lines="" f
  for f in "$gate_dir"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "verdict.json" ] && continue
    [ "$(jq -r '.verdict' "$f")" = "FAIL" ] || continue
    lines+="- $(jq -r '.ac_id' "$f") FAIL: \`$(jq -r '.cmd' "$f")\` → exit $(jq -r '.exit_code' "$f")"$'\n'
  done
  [ -n "$lines" ] || return 0
  printf '前次嘗試（attempt-%s）未通過驗收：\n%s請針對以上條件修正。驗收條件不變。\n' \
    "$attempt" "$lines"
}

# Centralized runs/ root (§8.1): same tree as dispatch results, outside any
# worker worktree (reinforces the §5 "worker cannot write runs/" boundary).
_ccs_dispatch_runs_dir() {
  local d; d="$(_ccs_dispatch_dir)/runs"; mkdir -p "$d"; echo "$d"
}

# Normalize a path to absolute (does not require existence; `-m`).
_ccs_dispatch_abspath() { realpath -m "$1"; }

# Resolve a task's `next:` to a normalized absolute path. Relative values are
# resolved against the CURRENT task file's directory (not the frozen copy, not
# cwd), so a chain author writes paths relative to where the task.yaml lives.
_ccs_dispatch_resolve_next() {
  local cur="$1" next="$2" base
  base="$(dirname "$cur")"
  case "$next" in
    /*) realpath -m "$next" ;;
    *)  realpath -m "$base/$next" ;;
  esac
}

# Allocate a fresh chain run dir <runs>/<first-id>-chain-NN. Seeds NN from the
# existing count, then claims the dir with a bare `mkdir` (bumping NN on
# collision) so concurrent chains of the same first task never share a dir.
_ccs_dispatch_chain_alloc_dir() {
  local first_id="$1" runs seq dir
  runs="$(_ccs_dispatch_runs_dir)"
  seq=$(( $(find "$runs" -maxdepth 1 -type d -name "${first_id}-chain-*" \
    2>/dev/null | wc -l) + 1 ))
  dir="$runs/${first_id}-chain-$(printf '%02d' "$seq")"
  while ! mkdir "$dir" 2>/dev/null; do
    seq=$((seq + 1))
    dir="$runs/${first_id}-chain-$(printf '%02d' "$seq")"
  done
  echo "$dir"
}

# SPAWN SEAM. Real impl runs the executor synchronously (headless claude -p) in
# <cwd> and captures evidence into attempt-NN/. Tests override this to simulate
# worker edits. Scope C drives synchronous headless execution; the agentpager
# async backend for the gate loop is deferred (see plan Deferred).
_ccs_dispatch_run_worker() {
  local cwd="$1" prompt="$2" run_dir="$3" attempt="$4"
  local timeout_sec="${5:-$CCS_DISPATCH_TIMEOUT}" executor="${6:-claude}"
  local ad="$run_dir/attempt-$(printf '%02d' "$attempt")"
  mkdir -p "$ad"
  # gemini needs --approval-mode yolo: headless has no tty, so without
  # auto-approve it cannot run edit tools. The deterministic gate re-runs every
  # verify.cmd against ground truth, so a yolo false-success is caught (see
  # docs/case-studies/gemini-yolo-overconfidence.md). claude is the default.
  local cmd
  case "$executor" in
    gemini) cmd=(gemini -p "$prompt" --approval-mode yolo) ;;
    *)      cmd=(claude -p "$prompt") ;;
  esac
  (cd "$cwd" && timeout "$timeout_sec" "${cmd[@]}") \
    > "$ad/executor-output.md" 2>&1 || true
  (cd "$cwd" && git status --porcelain) > "$ad/git-status.txt" 2>/dev/null || true
  (cd "$cwd" && git diff) > "$ad/diff.patch" 2>/dev/null || true
  return 0
}

# Run ONE task through the attempt loop into <hop_dir>: build prompt (attempt 1
# = goal; >=2 = §6 feedback + goal), spawn worker, run gate, branch on verdict.
# <task> is the already-loaded+validated task JSON; <task_yaml> is its source
# path (frozen into hop_dir). Writes attempt-NN evidence + final.json. Echoes
# the terminal verdict word; rc 0 accepted / 10 escalated / 11 hard_stop.
_ccs_dispatch_run_one() {
  local task="$1" task_yaml="$2" hop_dir="$3"
  local cwd budget goal timeout_sec executor
  cwd="$(echo "$task" | jq -r '.scope.cwd // "."')"
  budget="$(echo "$task" | jq -r ".execution_policy.loop_budget // $CCS_DISPATCH_GATE_LOOP_BUDGET")"
  goal="$(echo "$task" | jq -r '.goal')"
  executor="$(echo "$task" | jq -r '.executor // "claude"')"
  timeout_sec="$(echo "$task" | jq -r '.execution_policy.timeout_sec // empty')"
  [ -z "$timeout_sec" ] && timeout_sec="$CCS_DISPATCH_TIMEOUT"

  mkdir -p "$hop_dir"
  cp "$task_yaml" "$hop_dir/task.yaml"   # freeze (§1)

  local attempt=1 verdict outcome="escalated" rc=10 term="ESCALATE"
  local ad prev prompt fb
  while [ "$attempt" -le $(( budget + 1 )) ]; do
    ad="$hop_dir/attempt-$(printf '%02d' "$attempt")"
    mkdir -p "$ad"
    prompt="Task: $goal"
    if [ "$attempt" -gt 1 ]; then
      prev="$hop_dir/attempt-$(printf '%02d' $((attempt - 1)))"
      fb="$(_ccs_dispatch_gate_feedback "$prev" $((attempt - 1)))"
      prompt="${fb}"$'\n'"Task: $goal"
    fi
    printf '%s' "$prompt" > "$ad/prompt.md"

    _ccs_dispatch_run_worker "$cwd" "$prompt" "$hop_dir" "$attempt" "$timeout_sec" "$executor"
    verdict="$(_ccs_dispatch_gate_run "$cwd" "$task" "$ad" "$attempt" "$budget")"

    case "$verdict" in
      PASS)      outcome="accepted";  rc=0;  term="PASS";      break ;;
      HARD_STOP) outcome="hard_stop"; rc=11; term="HARD_STOP"; break ;;
      ESCALATE)  outcome="escalated"; rc=10; term="ESCALATE";  break ;;
      RETRY)     : ;;   # loop again
    esac
    attempt=$((attempt + 1))
  done

  jq -n --arg o "$outcome" --argjson n "$attempt" \
    '{outcome:$o, attempts:$n, stage2:null,
      escalation:(if $o=="escalated" then {reason:"gate"} else null end)}' \
    > "$hop_dir/final.json"
  echo "$term"
  return "$rc"
}

# Chain driver: run the first task, and follow `next:` on PASS.
# Echoes the chain run dir; rc 0 accepted / 10 escalated / 11 hard_stop of the
# terminal hop, or 2 on first-task load error (before any dir alloc).
_ccs_dispatch_run() {
  local first_yaml="$1"
  local cur; cur="$(_ccs_dispatch_abspath "$first_yaml")"
  local task; task="$(_ccs_dispatch_gate_load_task "$cur")" || return 2
  local first_id; first_id="$(echo "$task" | jq -r '.id')"

  local chain_dir; chain_dir="$(_ccs_dispatch_chain_alloc_dir "$first_id")"
  local max="$CCS_DISPATCH_CHAIN_MAX_DEPTH"

  local depth=0 hop_n=1 visited=" $cur " hops='[]'
  local term rc=0 stop_reason="" chain_outcome="accepted"
  local hop_id hop_dir attempts hop_outcome next nxt ntask
  while : ; do
    hop_id="$(echo "$task" | jq -r '.id')"
    hop_dir="$chain_dir/hop-$(printf '%02d' "$hop_n")-${hop_id}"
    term="$(_ccs_dispatch_run_one "$task" "$cur" "$hop_dir")"; rc=$?
    attempts="$(jq -r '.attempts' "$hop_dir/final.json")"
    hop_outcome="$(jq -r '.outcome' "$hop_dir/final.json")"
    hops="$(jq -n --argjson h "$hops" --argjson n "$hop_n" \
      --arg id "$hop_id" --arg o "$hop_outcome" --argjson a "$attempts" \
      --arg d "$hop_dir" \
      '$h + [{hop:$n, task_id:$id, outcome:$o, attempts:$a, dir:$d}]')"

    if [ "$term" != "PASS" ]; then          # ESCALATE / HARD_STOP
      chain_outcome="$hop_outcome"; stop_reason="$term"; break
    fi

    next="$(echo "$task" | jq -r '.next // empty')"
    stop_reason="$(_ccs_dispatch_chain_stop_reason \
      "handoff-ready" "done" "$next" "$depth" "$max")"
    [ -n "$stop_reason" ] && break          # empty-next (complete) / depth

    nxt="$(_ccs_dispatch_resolve_next "$cur" "$next")"
    case "$visited" in *" $nxt "*) stop_reason="cycle"; break ;; esac
    if ! ntask="$(_ccs_dispatch_gate_load_task "$nxt" 2>/dev/null)"; then
      stop_reason="failed"; break
    fi
    visited="$visited$nxt "
    task="$ntask"; cur="$nxt"; depth=$((depth + 1)); hop_n=$((hop_n + 1))
  done

  jq -n --arg cid "$(basename "$chain_dir")" --argjson hops "$hops" \
    --arg sr "$stop_reason" --arg o "$chain_outcome" --argjson d "$depth" \
    '{chain_id:$cid, hops:$hops, stopped_at_hop:($hops|length),
      stop_reason:$sr, outcome:$o, depth:$d}' \
    > "$chain_dir/chain.json"
  echo "$chain_dir"
  return "$rc"
}

# Public entry: verify args, run the scope-C gate loop, print outcome + evidence.
ccs-dispatch-run() {
  local task_yaml="${1:-}"
  if [ -z "$task_yaml" ] || [ "$task_yaml" = "-h" ] || [ "$task_yaml" = "--help" ]; then
    cat <<'HELP'
Usage: ccs-dispatch-run <task.yaml>
  Dispatch a worker, verify its output against the task's acceptance criteria
  (deterministic Stage-1 gate), retry once on FAIL with a machine-fact failure
  summary, and record structured evidence under the dispatch runs/ tree. On a
  PASS verdict, follow the task's optional next: field to run the next task
  (synchronous gated chain); the chain stops on non-PASS / empty-next / depth /
  cycle / next-load failure.
  Exit: 0 accepted / 10 escalated / 11 hard_stop.
HELP
    [ -z "$task_yaml" ] && return 1 || return 0
  fi
  local run_dir rc outcome
  run_dir="$(_ccs_dispatch_run "$task_yaml")"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "ccs-dispatch-run: could not load task: $task_yaml" >&2
    return 2
  fi
  echo "run: $run_dir"
  local hops sr
  hops="$(jq -r '.hops | length' "$run_dir/chain.json" 2>/dev/null || echo 1)"
  outcome="$(jq -r '.outcome' "$run_dir/chain.json" 2>/dev/null)"
  if [ "$hops" -le 1 ]; then
    echo "outcome: $outcome (see $run_dir/chain.json)"
  else
    sr="$(jq -r '.stop_reason' "$run_dir/chain.json")"
    echo "chain: $hops hops, outcome=$outcome, stop=$sr (see $run_dir/chain.json)"
  fi
  return "$rc"
}

# Public entry: expand a chain-spec YAML into a next:-linked set of task.yaml
# files (deterministic; no execution). Print the entry task path to stdout so it
# composes: ccs-dispatch-run "$(ccs-dispatch-plan spec.yaml)". Two-step by design:
# the human inspects the generated chain before dispatching.
ccs-dispatch-plan() {
  local spec="${1:-}" out=""
  if [ -z "$spec" ] || [ "$spec" = "-h" ] || [ "$spec" = "--help" ]; then
    cat <<'HELP'
Usage: ccs-dispatch-plan <chain-spec.yaml> [--out <dir>]
  Expand a structured chain-spec into a next:-linked set of task.yaml files
  (deterministic; does NOT dispatch). Prints the entry task path to stdout.
  Then inspect the files and run:  ccs-dispatch-run <entry-path>
  Default out dir: <dir-of-spec>/chain
HELP
    [ -z "$spec" ] && return 1 || return 0
  fi
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)
        [ $# -ge 2 ] || { echo "ccs-dispatch-plan: --out needs a value" >&2; return 1; }
        out="$2"; shift 2 ;;
      *) echo "ccs-dispatch-plan: unknown arg: $1" >&2; return 1 ;;
    esac
  done
  [ -f "$spec" ] || { echo "ccs-dispatch-plan: spec not found: $spec" >&2; return 1; }
  [ -z "$out" ] && out="$(dirname "$(_ccs_dispatch_abspath "$spec")")/chain"
  local entry
  entry="$(_ccs_dispatch_plan_generate "$spec" "$out")" || return 1
  local -a _hops=("$out"/hop-*.task.yaml); local n="${#_hops[@]}"
  echo "ccs-dispatch-plan: generated $n hop(s) -> $out" >&2
  echo "ccs-dispatch-plan: dispatch with: ccs-dispatch-run $entry" >&2
  echo "$entry"
}

# ── Job ID: d-YYYYMMDD-HHMMSS-XXXX ──
_ccs_dispatch_job_id() {
  printf 'd-%s-%s' \
    "$(date +%Y%m%d-%H%M%S)" \
    "$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# Append a job record to jobs.jsonl
_ccs_dispatch_jsonl_append() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  echo "$1" >> "$dispatch_dir/jobs.jsonl"
}

# Read merged record for a job_id (reduce-merge: all fields, later wins)
_ccs_dispatch_jsonl_latest() {
  local job_id="$1"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local f="$dispatch_dir/jobs.jsonl"
  [ -f "$f" ] || return 1
  grep "\"job_id\":\"${job_id}\"" "$f" \
    | jq -s 'reduce .[] as $r ({}; . + $r)'
}

_ccs_dispatch_finish() {
  local job_id="$1" exit_code="$2"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local raw="$dispatch_dir/results/${job_id}.raw"
  local err="$dispatch_dir/results/${job_id}.err"
  local md="$dispatch_dir/results/${job_id}.md"
  local prompt_f="$dispatch_dir/results/${job_id}.prompt"

  # Determine status
  local status
  case "$exit_code" in
    0)   status="completed" ;;
    124) status="timeout" ;;
    *)   status="failed" ;;
  esac

  # Read task from prompt file
  local task=""
  [ -f "$prompt_f" ] && task=$(head -c 200 "$prompt_f")

  # Read initial record for metadata
  local initial
  initial=$(_ccs_dispatch_jsonl_latest "$job_id")
  local project created_at
  project=$(echo "$initial" | jq -r '.project // "unknown"')
  created_at=$(echo "$initial" | jq -r '.created_at // "unknown"')
  local backend
  backend=$(echo "$initial" | jq -r '.backend // "headless"')
  local finished_at
  finished_at=$(date -Iseconds)

  # Calculate duration
  local duration_s=""
  if [ "$created_at" != "unknown" ]; then
    local start_epoch end_epoch
    start_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "")
    end_epoch=$(date +%s)
    if [ -n "$start_epoch" ]; then
      duration_s="$((end_epoch - start_epoch))s"
    fi
  fi

  # Build structured markdown
  {
    echo "# Dispatch Result: $job_id"
    echo ""
    echo "- **Project:** $project"
    echo "- **Task:** $task"
    echo "- **Status:** $status"
    echo "- **Exit code:** $exit_code"
    echo "- **Backend:** $backend"
    echo "- **Created:** $created_at"
    echo "- **Finished:** $finished_at"
    [ -n "$duration_s" ] && echo "- **Duration:** $duration_s"
    echo ""
    echo "## Output"
    echo ""
    if [ -f "$raw" ] && [ -s "$raw" ]; then
      cat "$raw"
    else
      echo "(no output)"
    fi
    echo ""
    echo "## Errors"
    echo ""
    if [ -f "$err" ] && [ -s "$err" ]; then
      cat "$err"
    else
      echo "(none)"
    fi
  } > "$md"

  # Extract summary
  local summary=""
  if [ -f "$raw" ]; then
    summary=$(tail -n "$CCS_DISPATCH_SUMMARY_LINES" "$raw" | head -c "$CCS_DISPATCH_SUMMARY_MAX_CHARS")
  fi

  # Update JSONL
  _ccs_dispatch_jsonl_append "$(jq -nc \
    --arg jid "$job_id" \
    --arg st "$status" \
    --arg ec "$exit_code" \
    --arg fa "$finished_at" \
    --arg sum "$summary" \
    '{job_id:$jid, status:$st, exit_code:($ec|tonumber), finished_at:$fa, summary:$sum}'
  )"

  # Cleanup temp files — keep .err for debugging
  rm -f "$dispatch_dir/pids/${job_id}.pid"
  [ -f "$md" ] && rm -f "$raw"
  rm -f "$prompt_f"
}

# Consume a framed agent-pager local-channel stream and emit each frame's
# BODY to stdout (one per frame, newline-joined). Label is ignored — ccs
# surfaces body only. Reads $1 (file path) or stdin.
# Frame layout (agent-pager notify-send.sh local sink):
#   <RS>MSG<US><LABEL><RS>\n<BODY>\n<RS>END<RS>\n   (RS=0x1E, US=0x1F)
_ccs_consume_framed_stream() {
  local src="${1:-/dev/stdin}"
  awk -v RS=$'\x1e' -v us=$'\x1f' '
    BEGIN { in_msg=0; expect_body=0; n=0 }
    $0 ~ "^MSG" us        { in_msg=1; expect_body=1; next }
    in_msg && expect_body { body=$0; sub(/^\n/,"",body); sub(/\n$/,"",body); expect_body=0; next }
    in_msg && $0 ~ "^END" { bodies[n++]=body; in_msg=0 }
    END { for (i=0;i<n;i++) { if (i) printf "\n"; printf "%s", bodies[i] } printf "\n" }
  ' "$src"
}

# Map an absolute project_dir to the lead-side proj key that ccs writes
# into the inbound .md. ccs keeps its OWN map (key = abspath, same format
# as the lead whitelist) via CCS_DISPATCH_PROJ_MAP so it never reads the
# lead's projects file. Echoes the key; rc 1 if no map / no match.
_ccs_dispatch_resolve_proj_from_dir() {
  local dir="${1%/}" line key val
  local map_file="${CCS_DISPATCH_PROJ_MAP:-$HOME/.config/ccs-dashboard/proj-map}"
  [ -f "$map_file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    [ "${val%/}" = "$dir" ] && { printf '%s\n' "$key"; return 0; }
  done < "$map_file"
  return 1
}

# ── agent-pager backend (stage 2) ──────────────────────────────────────────
# Dispatch a worker over the agent-pager local channel: write an inbound launch,
# then watch the per-user out.stream + the worker's handoff file back into a job
# result. Completion is signalled by the worker writing tmp/handoff-<job_id>.md
# (design Decision B): ccs then stops the seat and finalizes. There is NO
# wall-clock kill — a stuck worker stays up for the operator to /stop (design D2).

# Build the worker's opening prompt: the dispatch prompt plus a handoff-gating
# invariant that tells the worker to write tmp/handoff-<job_id>.md when done
# (that file is ccs's completion signal). ccs-handoff's own default output path
# differs, so the worker is told to save to this exact per-job path.
_ccs_dispatch_agentpager_prompt() {
  local job_id="$1" task="$2"
  cat <<HGRULE
${task}

---
DISPATCH HANDOFF RULE (job ${job_id}, non-negotiable):
This is a dispatched worker session. When the task above is fully complete (or
before your context fills), first report a one-line summary of what you did.
Then, AS YOUR VERY LAST ACTION, write a concise handoff to the file
tmp/handoff-${job_id}.md (path relative to the project root; use ccs-handoff for
the content if helpful). Begin that file with a YAML frontmatter block the
dispatcher parses for the job board — the lead reads this line instead of your
full transcript, so make it a clean standalone summary:
---
summary: <one line, <=120 chars, what you accomplished>
outcome: done | partial | blocked
next: <one line, the next step if any — omit if none>
---
Writing tmp/handoff-${job_id}.md is your completion signal: the dispatcher
watches for it and closes this session once it appears, so do not create it
until everything else — including your summary — is already done. You do NOT
need to exit yourself.

AUTONOMY (this is an unattended dispatched session):
Do not ask clarifying questions and do not wait on terminal input. If a detail
is ambiguous, make a reasonable assumption, proceed, and record the assumption
in your handoff. If you are genuinely blocked and cannot proceed, do NOT stall
waiting for input — set outcome: blocked in the handoff frontmatter and explain
what you need. A blocked handoff surfaces the question to the operator.
HGRULE
}

# Extract the `<field>:` value from a handoff file's leading YAML frontmatter.
# Only a properly CLOSED `---`-delimited block at the top of the file is
# honoured: the value is emitted only once the closing `---` is seen, so a
# `<field>:` in the body (or an unterminated frontmatter block) is never
# mistaken for the header field. First occurrence wins. CRLF tolerated.
# Echoes the trimmed value (empty if no frontmatter / no closing / no field);
# always rc 0.
_ccs_dispatch_parse_handoff_field() {
  local f="$1" field="$2"
  [ -f "$f" ] || return 0
  awk -v key="$field" '
    { sub(/\r$/, "") }                   # tolerate CRLF
    NR==1 && $0 != "---" { exit }        # no frontmatter -> nothing to read
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" {               # closing delimiter: block is valid
      print found; exit
    }
    in_fm && found == "" && index($0, key ":") == 1 {
      val = substr($0, length(key) + 2)  # drop "key:"
      sub(/^[[:space:]]*/, "", val)
      sub(/[[:space:]]+$/, "", val)
      found = val
    }
  ' "$f"
}

# Extract the `summary:` frontmatter field (see _ccs_dispatch_parse_handoff_field
# for the exact semantics). Kept as a named helper for its existing callers.
_ccs_dispatch_parse_handoff_summary() {
  _ccs_dispatch_parse_handoff_field "$1" summary
}

# Build the context preamble that prefixes a chained hop's task. The parent
# handoff is the chain's context carrier (design §9.3): the next worker cold-
# starts, so it must be told what the previous worker did. Emits the parent
# summary line plus the handoff body (frontmatter stripped), capped to
# ~CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS bytes (head -c; a soft ceiling that may
# slice a trailing multibyte char). Empty output when the file is absent.
_ccs_dispatch_chain_context_bridge() {
  local handoff="$1"
  [ -f "$handoff" ] || return 0
  local summary body
  summary="$(_ccs_dispatch_parse_handoff_field "$handoff" summary)"
  # Body = everything after a closed leading frontmatter block; if there is no
  # frontmatter, the whole file is the body.
  body="$(awk '
    NR==1 && $0 != "---" { print; body=1; next }
    NR==1 { in_fm=1; next }
    in_fm && $0 == "---" { in_fm=0; body=1; next }
    in_fm { next }
    body { print }
  ' "$handoff" | head -c "$CCS_DISPATCH_CHAIN_BRIDGE_MAX_CHARS")"
  printf 'You are continuing a chained task. The previous worker reported:\n'
  [ -n "$summary" ] && printf '  %s\n' "$summary"
  printf '\nIts full handoff (your context) follows:\n'
  printf -- '---\n%s\n---\n\n' "$body"
}

# Pure continuation predicate. Returns an empty string when the chain should
# CONTINUE (outcome==done AND next non-empty AND depth<max), or a verbatim stop
# reason otherwise (partial / blocked / failed / depth / empty-next). No side
# effects. See spec §2 (predicate) and §6 (reason strings).
_ccs_dispatch_chain_stop_reason() {
  local status="$1" outcome="$2" next="$3" depth="$4" max="$5"
  if [ "$status" != "handoff-ready" ]; then
    printf 'failed\n'; return 0
  fi
  case "$outcome" in
    done)    : ;;                       # candidate to continue; checks below
    partial) printf 'partial\n'; return 0 ;;
    blocked) printf 'blocked\n'; return 0 ;;
    *)       printf 'failed\n'; return 0 ;;  # empty / unknown outcome
  esac
  if [ -z "$next" ]; then
    printf 'empty-next\n'; return 0
  fi
  if [ "$depth" -ge "$max" ]; then
    printf 'depth\n'; return 0
  fi
  printf '\n'                            # continue
}

# Write an agent-pager inbound launch file. Frontmatter matches inbound-handler.sh
# (kind/slot/proj/cli + two --- delimiters, body after the second). ccs passes a
# proj KEY only — agent-pager resolves it to a path from its own whitelist (the
# RCE boundary). Echoes the file path; rc 1 on write failure.
_ccs_dispatch_agentpager_launch_file() {
  local job_id="$1" proj="$2" key="$3" prompt="$4" pager_dir="$5"
  local inbound="$pager_dir/inbound"
  mkdir -p "$inbound" || return 1
  local f="$inbound/$(date +%s)-${job_id}.md"
  {
    printf -- '---\n'
    printf 'kind: launch\n'
    printf 'slot: %s\n' "$key"
    printf 'proj: %s\n' "$proj"
    printf 'cli: claude\n'
    printf -- '---\n'
    printf '%s\n' "$prompt"
  } > "$f" || return 1
  printf '%s\n' "$f"
}

# Write an agent-pager inbound stop file to reclaim the local seat. Echoes the
# path; rc 1 on write failure.
_ccs_dispatch_agentpager_stop_file() {
  local key="$1" pager_dir="$2"
  local inbound="$pager_dir/inbound"
  mkdir -p "$inbound" || return 1
  local f="$inbound/$(date +%s%N)-${key}-stop.md"
  {
    printf -- '---\n'
    printf 'kind: stop\n'
    printf 'slot: %s\n' "$key"
    printf -- '---\n'
  } > "$f" || return 1
  printf '%s\n' "$f"
}

# Decode only this job's frames from the per-user out.stream. The stream is
# append-only and persists across jobs, so we read from the byte offset captured
# at launch, not the whole file.
_ccs_dispatch_agentpager_collect() {
  local stream="$1" offset="$2" dest="$3"
  if [ -f "$stream" ]; then
    tail -c +$((offset + 1)) "$stream" | _ccs_consume_framed_stream > "$dest"
  else
    : > "$dest"
  fi
}

# True while the worker's tmux session is alive. Wrapped so tests can mock tmux.
_ccs_dispatch_agentpager_session_alive() {
  tmux has-session -t "$1" 2>/dev/null
}

# Echo the last-activity timestamp (ISO) of a local session = mtime of its
# out.stream. Lets ccs-jobs surface a stalled worker so the operator can /stop
# it (design D2: no auto-kill). Empty if the stream does not exist yet.
_ccs_dispatch_agentpager_last_activity() {
  local key="$1" pager_dir="$2"
  local stream="$pager_dir/channels/$key/out.stream"
  [ -f "$stream" ] || return 0
  date -Iseconds -r "$stream" 2>/dev/null
}

# Resolve the agent-pager outbound sender (notify-send.sh). Order: the
# AGENT_PAGER_SENDER convention (agent-pager's own scripts honor it), then a
# sibling of the runner unit's ExecStart script — the services run straight
# from the checkout, so the unit is the one place that knows the bin dir.
# Empty output = no sender available; callers skip the notification.
_ccs_dispatch_notify_sender() {
  if [ -n "${AGENT_PAGER_SENDER:-}" ] && [ -x "$AGENT_PAGER_SENDER" ]; then
    echo "$AGENT_PAGER_SENDER"; return 0
  fi
  local exec_start script_path candidate
  exec_start="$(systemctl --user show agent-pager-runner.service -p ExecStart 2>/dev/null)" || return 0
  script_path="$(echo "$exec_start" | grep -o 'path=[^ ;]*' | head -1 | cut -d= -f2-)"
  [ -n "$script_path" ] || return 0
  candidate="$(dirname "$script_path")/notify-send.sh"
  [ -x "$candidate" ] && echo "$candidate"
  return 0
}

# Best-effort completion notification for an agentpager job (#74). Sends one
# short pager message via notify-send.sh at finalize. Never fails the caller:
# a missing sender or a send error is silently ignored (the sender itself
# always exits 0). CCS_DISPATCH_NOTIFY=0 opts out entirely; the send is opted
# in per call (AGENT_PAGER_NOTIFY=1, the launching-caller convention), while
# the actual delivery still depends on agent-pager's own telegram config.
_ccs_dispatch_notify_completion() {
  [ "${CCS_DISPATCH_NOTIFY:-1}" != "0" ] || return 0
  local job_id="$1" status="$2" project="$3" handoff_dst="$4" note="$5"
  local sender
  sender="$(_ccs_dispatch_notify_sender)"
  [ -n "$sender" ] && [ -x "$sender" ] || return 0
  {
    # No prefix here: notify-send.sh already prepends the --label.
    echo "$job_id $status"
    echo "project: $project"
    [ -n "$handoff_dst" ] && echo "handoff: $handoff_dst"
    [ -n "$note" ] && echo "note: $note"
  } | AGENT_PAGER_NOTIFY=1 \
    AGENT_PAGER_BOT_SLOT="${CCS_DISPATCH_NOTIFY_SLOT:-1}" \
    timeout "${CCS_DISPATCH_NOTIFY_TIMEOUT:-10}" \
    "$sender" --cwd "$HOME" --label "ccs-dispatch" \
    >/dev/null 2>&1 || true
  return 0
}

# Finalize an agent-pager job (handoff gating). Handoff file present + copied ->
# handoff-ready (captured to results/<job_id>.handoff). Otherwise the status is
# $3 (no_handoff_status, default "completed"; the monitor passes "failed" when
# the worker session was never observed). ccs is not the worker's parent, so
# there is no exit code. $4 is an optional operator note appended to md + jsonl.
_ccs_dispatch_finish_agentpager() {
  local job_id="$1" handoff_src="$2"
  local no_handoff_status="${3:-completed}" note="${4:-}"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local raw="$dispatch_dir/results/${job_id}.raw"
  local err="$dispatch_dir/results/${job_id}.err"
  local md="$dispatch_dir/results/${job_id}.md"
  local handoff_dst="$dispatch_dir/results/${job_id}.handoff"
  local prompt_f="$dispatch_dir/results/${job_id}.prompt"

  # handoff-ready only when the file is actually captured; a failed copy must not
  # claim a handoff it did not save.
  local status handoff_flag=false
  if [ -f "$handoff_src" ] && cp "$handoff_src" "$handoff_dst" 2>/dev/null; then
    handoff_flag=true
    status="handoff-ready"
  else
    [ -f "$handoff_src" ] && note="${note:+$note; }handoff present but copy failed"
    status="$no_handoff_status"
  fi

  local task=""
  [ -f "$prompt_f" ] && task=$(head -c 200 "$prompt_f")
  local initial project created_at backend
  initial=$(_ccs_dispatch_jsonl_latest "$job_id")
  project=$(echo "$initial" | jq -r '.project // "unknown"')
  created_at=$(echo "$initial" | jq -r '.created_at // "unknown"')
  backend=$(echo "$initial" | jq -r '.backend // "agentpager"')
  local finished_at
  finished_at=$(date -Iseconds)

  local duration_s=""
  if [ "$created_at" != "unknown" ]; then
    local start_epoch
    start_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "")
    [ -n "$start_epoch" ] && duration_s="$(( $(date +%s) - start_epoch ))s"
  fi

  {
    echo "# Dispatch Result: $job_id"
    echo ""
    echo "- **Project:** $project"
    echo "- **Task:** $task"
    echo "- **Status:** $status"
    echo "- **Backend:** $backend"
    echo "- **Created:** $created_at"
    echo "- **Finished:** $finished_at"
    [ -n "$duration_s" ] && echo "- **Duration:** $duration_s"
    [ "$handoff_flag" = true ] && echo "- **Handoff:** $handoff_dst"
    [ -n "$note" ] && echo "- **Note:** ⚠️ $note"
    echo ""
    echo "## Output"
    echo ""
    # A zero-frame stream collects to a lone newline, so test emptiness by
    # non-whitespace content, not just file size.
    if [ -f "$raw" ] && grep -q '[^[:space:]]' "$raw" 2>/dev/null; then
      cat "$raw"
    else
      echo "(no output)"
    fi
    echo ""
    echo "## Errors"
    echo ""
    if [ -f "$err" ] && [ -s "$err" ]; then
      cat "$err"
    else
      echo "(none)"
    fi
  } > "$md"

  # Prefer the worker's structured handoff frontmatter summary (a clean, intended
  # one-liner) over the raw-transcript tail, which is noisy. Fall back to the tail
  # only when no frontmatter summary is present.
  local summary=""
  if [ "$handoff_flag" = true ]; then
    summary=$(_ccs_dispatch_parse_handoff_summary "$handoff_dst")
  fi
  if [ -z "$summary" ] && [ -f "$raw" ]; then
    summary=$(tail -n "$CCS_DISPATCH_SUMMARY_LINES" "$raw" | head -c "$CCS_DISPATCH_SUMMARY_MAX_CHARS")
  fi

  _ccs_dispatch_jsonl_append "$(jq -nc \
    --arg jid "$job_id" \
    --arg st "$status" \
    --arg fa "$finished_at" \
    --arg sum "$summary" \
    --arg note "$note" \
    --argjson ho "$handoff_flag" \
    '{job_id:$jid, status:$st, finished_at:$fa, summary:$sum, handoff:$ho}
     + (if $note == "" then {} else {note:$note} end)'
  )"

  rm -f "$dispatch_dir/pids/${job_id}.pid"
  [ -f "$md" ] && rm -f "$raw"
  rm -f "$prompt_f"

  # Notify after the job record is fully landed, so a pager reader who reacts
  # immediately sees the final state. Sync's stale reconciliation does not come
  # through here, so only a live finalize notifies.
  local notify_handoff=""
  [ "$handoff_flag" = true ] && notify_handoff="$handoff_dst"
  _ccs_dispatch_notify_completion "$job_id" "$status" "$project" \
    "$notify_handoff" "$note"
}

# Best-effort chain-termination pager notify (spec §7): one short message with
# the stop reason when a chain ends. "complete" for a clean end (empty-next /
# depth), "stopped" otherwise. Never fails the caller. CCS_DISPATCH_NOTIFY=0
# opts out (shared with the per-job completion notify).
_ccs_dispatch_chain_notify() {
  [ "${CCS_DISPATCH_NOTIFY:-1}" != "0" ] || return 0
  local job_id="$1" reason="$2" project="$3" depth="$4"
  local sender
  sender="$(_ccs_dispatch_notify_sender)"
  [ -n "$sender" ] && [ -x "$sender" ] || return 0
  local verb="stopped"
  case "$reason" in empty-next|depth) verb="complete" ;; esac
  {
    echo "chain ${verb}: ${reason}"
    echo "last job: ${job_id} (depth ${depth})"
    echo "project: ${project}"
  } | AGENT_PAGER_NOTIFY=1 \
    AGENT_PAGER_BOT_SLOT="${CCS_DISPATCH_NOTIFY_SLOT:-1}" \
    timeout "${CCS_DISPATCH_NOTIFY_TIMEOUT:-10}" \
    "$sender" --cwd "$HOME" --label "ccs-dispatch" \
    >/dev/null 2>&1 || true
  return 0
}

# Chain continuation engine (spec §2-§7). Called by the monitor after a job is
# finalized. Reads the just-captured handoff's outcome/next, evaluates the
# continuation predicate, and either stops the chain (record chain_stopped +
# terminal notify) or mints + launches the next hop and re-enters the monitor.
# The chain is single-project by construction: the next hop inherits the parent
# project_dir and re-resolves the SAME proj key (no cross-project branch).
_ccs_dispatch_chain_next() {
  local job_id="$1" key="$2" project_dir="$3" pager_dir="$4"
  local chain_depth="$5" max_depth="$6"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local handoff_dst="$dispatch_dir/results/${job_id}.handoff"

  local status outcome next_task project reason
  status="$(_ccs_dispatch_jsonl_latest "$job_id" | jq -r '.status // ""')"
  outcome="$(_ccs_dispatch_parse_handoff_field "$handoff_dst" outcome)"
  next_task="$(_ccs_dispatch_parse_handoff_field "$handoff_dst" next)"
  project="$(_ccs_dispatch_jsonl_latest "$job_id" | jq -r '.project // "unknown"')"
  reason="$(_ccs_dispatch_chain_stop_reason \
    "$status" "$outcome" "$next_task" "$chain_depth" "$max_depth")"

  if [ -n "$reason" ]; then
    _ccs_dispatch_jsonl_append "$(jq -nc \
      --arg jid "$job_id" --arg r "$reason" \
      '{job_id:$jid, chain_stopped:$r}')"
    _ccs_dispatch_chain_notify "$job_id" "$reason" "$project" "$chain_depth"
    return 0
  fi

  # Continue: resolve the inherited proj key. Same dir the parent used, so this
  # succeeds unless the proj-map changed mid-chain; if it cannot resolve, stop.
  local proj
  if ! proj="$(_ccs_dispatch_resolve_proj_from_dir "$project_dir")"; then
    _ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$job_id" \
      '{job_id:$jid, chain_stopped:"failed",
        note:"chain: parent proj key no longer resolvable"}')"
    _ccs_dispatch_chain_notify "$job_id" "failed" "$project" "$chain_depth"
    return 0
  fi

  local next_job_id next_depth
  next_job_id="$(_ccs_dispatch_job_id)"
  next_depth=$((chain_depth + 1))

  # Lineage record for the new hop (running).
  _ccs_dispatch_jsonl_append "$(jq -nc \
    --arg jid "$next_job_id" \
    --arg proj "$project" \
    --arg t "$next_task" \
    --arg be "agentpager" \
    --arg ca "$(date -Iseconds)" \
    --arg cp "$job_id" \
    --argjson cd "$next_depth" \
    --argjson cm "$max_depth" \
    '{job_id:$jid, project:$proj, task:$t, backend:$be, status:"running",
      created_at:$ca, chain:true, chain_parent:$cp, chain_depth:$cd,
      chain_max:$cm}')"
  printf '%s' "$next_task" > "$dispatch_dir/results/${next_job_id}.prompt"

  # Build the next worker prompt: parent context bridge + verification rule +
  # the next task, then wrapped by the handoff rule + autonomy invariant.
  local bridge vrule inner worker_prompt
  bridge="$(_ccs_dispatch_chain_context_bridge "$handoff_dst")"
  vrule="$(_ccs_dispatch_verification_rule)"
  inner="${bridge}${vrule}Task: ${next_task}"
  worker_prompt="$(_ccs_dispatch_agentpager_prompt "$next_job_id" "$inner")"

  # Launch offset: only capture the new hop's frames.
  local stream start_offset=0
  stream="$pager_dir/channels/$key/out.stream"
  [ -f "$stream" ] && start_offset="$(stat -c %s "$stream" 2>/dev/null || echo 0)"

  if ! _ccs_dispatch_agentpager_launch_file \
        "$next_job_id" "$proj" "$key" "$worker_prompt" "$pager_dir" >/dev/null; then
    _ccs_dispatch_jsonl_append "$(jq -nc --arg jid "$next_job_id" \
      '{job_id:$jid, status:"failed", chain_stopped:"failed",
        note:"chain: launch write failed"}')"
    _ccs_dispatch_chain_notify "$next_job_id" "failed" "$project" "$next_depth"
    return 0
  fi

  # This same background process keeps owning the chain: register its pid under
  # the new hop so ccs-jobs sync defers to the live monitor, then re-enter.
  echo $$ > "$dispatch_dir/pids/${next_job_id}.pid"
  _ccs_dispatch_agentpager_monitor "$next_job_id" "$key" "$project_dir" \
    "$start_offset" "$pager_dir" 1 "$next_depth" "$max_depth" "$job_id"
}

# Background monitor for one agent-pager job. Runs under nohup from spawn. Polls
# for the handoff file; when it appears, stops the seat and finalizes. Also exits
# the loop if the worker's tmux session disappears on its own (self /exit or
# crash). No wall-clock timeout (design D2: never auto-kill).
_ccs_dispatch_agentpager_monitor() {
  local job_id="$1" key="$2" project_dir="$3" start_offset="$4" pager_dir="$5"
  local chain_enabled="${6:-0}" chain_depth="${7:-0}" max_depth="${8:-5}"
  # Slot 9 (chain_parent) is accepted for call-site symmetry but not read here:
  # chain_next derives the parent from the finished job_id it is handed.
  local _chain_parent="${9:-}"
  local tmux_session="agent-pager-$key"
  local stream="$pager_dir/channels/$key/out.stream"
  local state_json="$pager_dir/state/sessions/$key.json"
  local handoff_src="$project_dir/tmp/handoff-${job_id}.md"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local poll="${CCS_DISPATCH_AGENTPAGER_POLL:-3}"
  local startup="${CCS_DISPATCH_AGENTPAGER_STARTUP:-60}"
  local stop_wait="${CCS_DISPATCH_AGENTPAGER_STOP_WAIT:-30}"
  local observed=0 note=""

  # Phase A — startup grace. The runner spawns the worker's tmux session a few
  # seconds after ccs writes the launch, so has-session is false right now.
  # Wait for it to appear before the completion loop; otherwise the monitor would
  # read "already gone" and finalize before the worker even runs.
  local waited=0
  while [ "$waited" -lt "$startup" ]; do
    if _ccs_dispatch_agentpager_session_alive "$tmux_session"; then observed=1; break; fi
    [ -f "$handoff_src" ] && break
    sleep 1; waited=$((waited + 1))
  done

  # Watch the cwd agent-pager ACTUALLY resolved the proj key to (its state json),
  # not ccs's project_dir. This is the single source of truth for where the worker
  # runs, so the handoff path can never drift from a stale proj-map entry.
  if [ -r "$state_json" ]; then
    local real_cwd
    real_cwd="$(jq -r '.cwd // empty' "$state_json" 2>/dev/null)"
    [ -n "$real_cwd" ] && [ -d "$real_cwd" ] && \
      handoff_src="$real_cwd/tmp/handoff-${job_id}.md"
  fi

  # Phase B — completion. Handoff file appears -> stop the seat; or the worker
  # ends the session on its own. No wall-clock kill (design D2).
  while _ccs_dispatch_agentpager_session_alive "$tmux_session"; do
    observed=1
    if [ -f "$handoff_src" ]; then
      # The worker writes the handoff mid-turn, but its tool/prose frames only
      # relay to out.stream at turn end. Wait for the stream to settle before
      # stopping, or an eager stop truncates the captured output (E2E-observed).
      _ccs_dispatch_agentpager_wait_settle "$stream"
      # Reclaim the seat. If the first stop is not honored (worker mid-tool-call),
      # retry once; if it still will not die, leave a note so the operator knows
      # to reclaim manually rather than silently orphaning the single per-user seat.
      _ccs_dispatch_agentpager_stop_file "$key" "$pager_dir" >/dev/null
      _ccs_dispatch_agentpager_wait_gone "$tmux_session" "$stop_wait"
      if _ccs_dispatch_agentpager_session_alive "$tmux_session"; then
        _ccs_dispatch_agentpager_stop_file "$key" "$pager_dir" >/dev/null
        _ccs_dispatch_agentpager_wait_gone "$tmux_session" "$stop_wait"
        _ccs_dispatch_agentpager_session_alive "$tmux_session" && \
          note="worker session did not stop; reclaim manually (tmux $tmux_session)"
      fi
      break
    fi
    sleep "$poll"
  done
  sleep 1  # let any trailing frames flush to the stream
  _ccs_dispatch_agentpager_collect "$stream" "$start_offset" \
    "$dispatch_dir/results/${job_id}.raw"
  # A session that never appeared is a launch failure, not a clean completion.
  local no_handoff_status="completed"
  [ "$observed" = 0 ] && no_handoff_status="failed"
  _ccs_dispatch_finish_agentpager "$job_id" "$handoff_src" "$no_handoff_status" "$note"

  # Chain continuation: only when this dispatch opted in. chain_next evaluates
  # the predicate on the captured handoff and either stops or launches + re-
  # enters the monitor for the next hop (bounded by max_depth). (spec §3)
  [ "$chain_enabled" = 1 ] || return 0
  _ccs_dispatch_chain_next "$job_id" "$key" "$project_dir" "$pager_dir" \
    "$chain_depth" "$max_depth"
}

# Poll until the tmux session is gone or $2 seconds elapse. Extracted so the
# stop-reclaim path stays readable and the wait bound is testable.
_ccs_dispatch_agentpager_wait_gone() {
  local session="$1" limit="$2" waited=0
  while _ccs_dispatch_agentpager_session_alive "$session" && [ "$waited" -lt "$limit" ]; do
    sleep 1; waited=$((waited + 1))
  done
}

# Wait for the out.stream ($1) to stop growing (turn-end relay flushed), so a
# fast worker's frames are captured before we stop it. Breaks after the size is
# stable for QUIET consecutive checks, or after SETTLE seconds regardless.
_ccs_dispatch_agentpager_wait_settle() {
  local stream="$1"
  local grace="${CCS_DISPATCH_AGENTPAGER_SETTLE:-8}"
  local quiet="${CCS_DISPATCH_AGENTPAGER_SETTLE_QUIET:-2}"
  local last=-1 stable=0 waited=0 sz
  while [ "$waited" -lt "$grace" ]; do
    sz=0; [ -f "$stream" ] && sz="$(stat -c %s "$stream" 2>/dev/null || echo 0)"
    if [ "$sz" = "$last" ]; then
      stable=$((stable + 1)); [ "$stable" -ge "$quiet" ] && break
    else
      stable=0; last="$sz"
    fi
    sleep 1; waited=$((waited + 1))
  done
}

# agent-pager backend spawn. Async-only: writes an inbound launch and starts a
# background monitor, returning immediately. Returns 2 (dispatcher falls back to
# headless) for --sync, an unresolvable proj key, or an inbound write failure.
_ccs_dispatch_spawn_agentpager() {
  local job_id="$1" project_dir="$2" prompt="$3" timeout_secs="$4" mode="$5"
  local chain_enabled="${6:-0}" max_depth="${7:-5}"

  if [ "$mode" = "sync" ]; then
    echo "ccs-dispatch: agent-pager backend is async-only;" \
         "falling back to headless for --sync" >&2
    return 2
  fi

  local proj
  if ! proj="$(_ccs_dispatch_resolve_proj_from_dir "$project_dir")"; then
    echo "ccs-dispatch: no proj-map entry for $project_dir" \
         "(set \$CCS_DISPATCH_PROJ_MAP or ~/.config/ccs-dashboard/proj-map);" \
         "falling back to headless" >&2
    return 2
  fi

  local pager_dir="${AGENT_PAGER_DIR:-$HOME/.agent-pager}"
  local luser key stream start_offset=0
  luser="$(id -un)"
  key="local-$luser"

  # Single-worker per user (key local-<user>): a second concurrent dispatch would
  # share the same tmux session + out.stream and corrupt both jobs' output. Refuse
  # and fall back to headless while one is already running (multi-worker is v2).
  if _ccs_dispatch_agentpager_session_alive "agent-pager-$key"; then
    echo "ccs-dispatch: a local agent-pager worker (agent-pager-$key) is already" \
         "running; falling back to headless" >&2
    return 2
  fi

  stream="$pager_dir/channels/$key/out.stream"
  [ -f "$stream" ] && start_offset="$(stat -c %s "$stream" 2>/dev/null || echo 0)"

  local worker_prompt launch_file
  worker_prompt="$(_ccs_dispatch_agentpager_prompt "$job_id" "$prompt")"
  if ! launch_file="$(_ccs_dispatch_agentpager_launch_file \
        "$job_id" "$proj" "$key" "$worker_prompt" "$pager_dir")"; then
    echo "ccs-dispatch: failed to write agent-pager launch;" \
         "falling back to headless" >&2
    return 2
  fi

  local dispatch_dir script_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
  printf '%s' "$prompt" > "$dispatch_dir/results/${job_id}.prompt"

  if [ "${CCS_DISPATCH_AGENTPAGER_MONITOR:-1}" = "1" ]; then
    nohup bash -c '
      source "$6/ccs-dashboard.sh"
      _ccs_dispatch_agentpager_monitor "$1" "$2" "$3" "$4" "$5" "$7" 0 "$8" ""
    ' _ "$job_id" "$key" "$project_dir" "$start_offset" "$pager_dir" "$script_dir" \
      "$chain_enabled" "$max_depth" \
      > /dev/null 2>&1 &
    echo $! > "$dispatch_dir/pids/${job_id}.pid"
    disown
  fi
  return 0
}

_ccs_dispatch_spawn_headless() {
  local job_id="$1" project_dir="$2" prompt="$3"
  local timeout_secs="$4" mode="$5"
  local dispatch_dir script_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  script_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"

  # Write prompt to temp file (avoid shell injection)
  local prompt_file="$dispatch_dir/results/${job_id}.prompt"
  printf '%s' "$prompt" > "$prompt_file"

  if [ "$mode" = "sync" ]; then
    local rc=0
    (cd "$project_dir" && \
      timeout "$timeout_secs" claude -p "$(cat "$prompt_file")") \
      > "$dispatch_dir/results/${job_id}.raw" \
      2> "$dispatch_dir/results/${job_id}.err" \
      || rc=$?
    _ccs_dispatch_finish "$job_id" "$rc"
    return $rc
  else
    nohup bash -c '
      prompt=$(cat "$1")
      cd "$2" && \
      timeout "$3" claude -p "$prompt" \
        > "$4/results/$5.raw" \
        2> "$4/results/$5.err"
      rc=$?
      source "$6/ccs-dashboard.sh"
      _ccs_dispatch_finish "$5" $rc
    ' _ \
      "$prompt_file" \
      "$project_dir" \
      "$timeout_secs" \
      "$dispatch_dir" \
      "$job_id" \
      "$script_dir" \
      > /dev/null 2>&1 &
    echo $! > "$dispatch_dir/pids/${job_id}.pid"
    disown
  fi
}

# Dispatcher: pick backend, route, fall back to headless on agent-pager failure.
# Optional $6 = pre-resolved backend (avoids double-resolve from ccs-dispatch).
_ccs_dispatch_spawn() {
  local job_id="$1" project_dir="$2" prompt="$3"
  local timeout_secs="$4" mode="$5"
  local backend="${6:-$(_ccs_dispatch_resolve_backend)}"
  local chain_enabled="${7:-0}" max_depth="${8:-5}"

  _CCS_DISPATCH_LAST_BACKEND="$backend"
  if [ "$backend" = "agentpager" ]; then
    if _ccs_dispatch_spawn_agentpager \
         "$job_id" "$project_dir" "$prompt" "$timeout_secs" "$mode" \
         "$chain_enabled" "$max_depth"; then
      return 0
    fi
    _CCS_DISPATCH_LAST_BACKEND="headless"  # agent-pager failed -> fell back
  fi
  _ccs_dispatch_spawn_headless \
    "$job_id" "$project_dir" "$prompt" "$timeout_secs" "$mode"
}

_ccs_dispatch_lazy_cleanup() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local ttl="$CCS_DISPATCH_RESULT_TTL_DAYS"
  find "$dispatch_dir/results" -type f -mtime +"$ttl" -delete 2>/dev/null
  local pidfile
  for pidfile in "$dispatch_dir/pids"/*.pid; do
    [ -f "$pidfile" ] || continue
    kill -0 "$(cat "$pidfile")" 2>/dev/null || rm -f "$pidfile"
  done
  find "$dispatch_dir/results" -type f \
    \( -name "*.raw" -o -name "*.prompt" \) \
    -mmin +60 -delete 2>/dev/null
}

_ccs_dispatch_running_count() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local count=0
  local pidfile
  for pidfile in "$dispatch_dir/pids"/*.pid; do
    [ -f "$pidfile" ] || continue
    kill -0 "$(cat "$pidfile")" 2>/dev/null && count=$((count + 1))
  done
  echo "$count"
}

_ccs_dispatch_context() {
  local project_dir="$1"
  local ctx=""
  if git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
    local branch uncommitted
    branch=$(git -C "$project_dir" branch --show-current 2>/dev/null)
    uncommitted=$(git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ctx+="[Project: $project_dir]"$'\n'
    ctx+="[Git branch: $branch, uncommitted: $uncommitted files]"$'\n'
  fi
  ctx+=$'\n---\n'
  echo "$ctx"
}

# Returns a verification rule prepended to every dispatch prompt.
# Guards against Opus 4.8 tool-output confabulation (fabricated success narratives).
# See docs/case-studies/2026-06-23-opus-fabricated-output.md for root-cause analysis.
_ccs_dispatch_verification_rule() {
  cat <<'VRULE'
VERIFICATION RULE (applies to this entire session, non-negotiable):
After every tool call that creates or modifies an external resource —
gh issue create, gh pr create, git commit, git push, Write, Edit — you MUST:
1. Quote the exact tool_result line that confirms success before marking
   the step done.
2. Do NOT report a commit hash, PR URL, issue URL, or "file written"
   unless that exact string appears verbatim in a preceding tool_result.
3. If tool_result shows an error, exit code != 0, or only a bare URL
   (with no additional confirmation text), report the failure immediately.
   Never substitute a fabricated success narrative.
Completion pressure does not override this rule.
A reported failure is always preferable to a fabricated success.
---
VRULE
}

# Render the sign-off block an operator reads before approving a dispatch
# (#75). Narrow layout for phone reading; a long prompt folds to its head plus
# a size note (CCS_DISPATCH_PREVIEW_MAX_CHARS, default 1500).
_ccs_dispatch_preview_render() {
  local project="$1" backend="$2" mode="$3" timeout_secs="$4" prompt="$5"
  local chain_enabled="${6:-0}" max_depth="${7:-5}"
  local max="${CCS_DISPATCH_PREVIEW_MAX_CHARS:-1500}"
  local seat=""
  [ "$backend" = "agentpager" ] && seat=" (seat local-$(id -un))"
  echo "── dispatch preview ──"
  echo "project : $project"
  echo "backend : ${backend}${seat}"
  [ "$backend" = "agentpager" ] && \
    echo "          (falls back to headless if the seat is unavailable)"
  echo "mode    : $mode (timeout ${timeout_secs}s)"
  [ "$chain_enabled" = 1 ] && \
    echo "chain   : auto-continue up to ${max_depth} hops in this project" \
         "(worker reports done + next)"
  echo "prompt  : ${#prompt} chars"
  # Fold the middle, not the tail: the prompt ends with "Task: ...", which is
  # exactly what the operator signs off on. Char-based slicing keeps multibyte
  # prompts intact (head -c would cut mid-UTF-8).
  if [ "${#prompt}" -gt "$max" ]; then
    local half=$(( max / 2 ))
    printf '%s\n' "${prompt:0:half}"
    echo "··· (folded $(( ${#prompt} - half * 2 )) of ${#prompt} chars) ···"
    printf '%s\n' "${prompt: -half}"
  else
    printf '%s\n' "$prompt"
  fi
  echo "── end preview ──"
}

# Read the operator's verdict from stdin: y/yes (any case) approves (0),
# anything else — including EOF from a non-interactive caller and a silence
# timeout (CCS_DISPATCH_PREVIEW_TIMEOUT, default 60s) — rejects (1). A
# non-interactive agent flow is expected to hit EOF, show the printed preview
# to its user, and re-run with --yes once approved.
_ccs_dispatch_preview_confirm() {
  local reply=""
  printf 'Dispatch? [y/N] ' >&2
  IFS= read -r -t "${CCS_DISPATCH_PREVIEW_TIMEOUT:-60}" reply || return 1
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

ccs-dispatch() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
ccs-dispatch — dispatch task to Claude Code

Usage:
  ccs-dispatch --project <dir> "task"
  ccs-dispatch --sync --project <dir> "task"

Options:
  --sync           Blocking (default: async)
  --context        Inject git status + todos
  --timeout <secs> Override timeout
  --project <dir>  Target project (required)
  --preview        Show a sign-off block and ask before dispatching;
                   rejection / EOF / timeout aborts with no job record
  --yes            Skip the confirmation (with --preview: print and go)
  --chain          (agentpager only) auto-continue the chain: when a worker
                   reports outcome:done + next, launch the next worker in the
                   same project without asking again. Approved once up front.
  --max-depth <n>  Max chained hops (default 5); a runaway ceiling.
HELP
    return 0
  fi

  _ccs_dispatch_lazy_cleanup

  local mode="async" context=false preview=false assume_yes=false
  local timeout_secs="" project="" task=""
  local chain=false max_depth="$CCS_DISPATCH_CHAIN_MAX_DEPTH"
  while [ $# -gt 0 ]; do
    case "$1" in
      --sync) mode="sync"; shift ;;
      --context) context=true; shift ;;
      --timeout) timeout_secs="$2"; shift 2 ;;
      --project) project="$2"; shift 2 ;;
      --preview) preview=true; shift ;;
      --yes) assume_yes=true; shift ;;
      --chain) chain=true; shift ;;
      --max-depth)
        case "$2" in
          ''|*[!0-9]*)
            echo "ccs-dispatch: --max-depth needs a non-negative integer" >&2
            return 1 ;;
        esac
        max_depth="$2"; shift 2 ;;
      *) task="$1"; shift ;;
    esac
  done

  if [ -z "$project" ]; then
    echo "Error: --project is required" >&2; return 1
  fi
  if [ -z "$task" ]; then
    echo "Error: task description required" >&2; return 1
  fi
  if [ ! -d "$project" ]; then
    echo "Error: $project not found" >&2; return 1
  fi

  project="$(cd "$project" && pwd)"

  if [ -z "$timeout_secs" ]; then
    if [ "$mode" = "sync" ]; then
      timeout_secs="$CCS_DISPATCH_SYNC_TIMEOUT"
    else
      timeout_secs="$CCS_DISPATCH_TIMEOUT"
    fi
  fi

  local running
  running=$(_ccs_dispatch_running_count)
  if [ "$running" -ge "$CCS_DISPATCH_MAX_CONCURRENT_WARN" ]; then
    echo "Warning: $running jobs running" >&2
  fi

  local _vrule
  _vrule="$(_ccs_dispatch_verification_rule)"
  local prompt
  if $context; then
    prompt="$(_ccs_dispatch_context "$project")${_vrule}Task: $task"
  else
    prompt="${_vrule}Task: $task"
  fi

  local backend
  backend=$(_ccs_dispatch_resolve_backend)

  # --chain needs the agentpager monitor; headless is fire-and-forget with no
  # monitor to run the chain loop. Warn and dispatch a single job. (spec §3/§8)
  if $chain && [ "$backend" != "agentpager" ]; then
    echo "ccs-dispatch: --chain requires the agentpager backend;" \
         "dispatching a single (non-chained) job on $backend" >&2
    chain=false
  fi
  local chain_enabled=0; $chain && chain_enabled=1

  # Sign-off gate (#75): before the first side effect, so a rejection leaves
  # no job record and no worker. --yes keeps automation non-interactive.
  if $preview; then
    _ccs_dispatch_preview_render "$project" "$backend" "$mode" \
      "$timeout_secs" "$prompt" "$chain_enabled" "$max_depth"
    if ! $assume_yes && ! _ccs_dispatch_preview_confirm; then
      echo "ccs-dispatch: aborted (preview not approved)" >&2
      return 1
    fi
  fi

  local job_id
  job_id=$(_ccs_dispatch_job_id)
  _ccs_dispatch_jsonl_append "$(jq -nc \
    --arg jid "$job_id" \
    --arg proj "$project" \
    --arg t "$task" \
    --argjson ctx "$context" \
    --arg m "$mode" \
    --arg be "$backend" \
    --arg ca "$(date -Iseconds)" \
    --argjson ce "$chain_enabled" \
    --argjson md "$max_depth" \
    '{job_id:$jid, project:$proj, task:$t, context_injected:$ctx, mode:$m, backend:$be, status:"running", created_at:$ca}
     + (if $ce == 1 then {chain:true, chain_depth:0, chain_max:$md} else {} end)'
  )"

  local spawn_rc=0
  _ccs_dispatch_spawn "$job_id" "$project" "$prompt" \
    "$timeout_secs" "$mode" "$backend" "$chain_enabled" "$max_depth" || spawn_rc=$?

  if [ "${_CCS_DISPATCH_LAST_BACKEND:-$backend}" != "$backend" ]; then
    _ccs_dispatch_jsonl_append "$(jq -nc \
      --arg jid "$job_id" \
      --arg be "$_CCS_DISPATCH_LAST_BACKEND" \
      '{job_id:$jid, backend:$be, fallback:true}')"
  fi

  if [ "$mode" = "sync" ]; then
    local dispatch_dir
    dispatch_dir="$(_ccs_dispatch_dir)"
    local md="$dispatch_dir/results/${job_id}.md"
    if [ -f "$md" ]; then
      echo "Job $job_id completed. Result: $md"
    else
      echo "Job $job_id finished (no result)."
    fi
  else
    echo "Job dispatched: $job_id"
    echo "Check: ccs-jobs $job_id"
  fi
}

ccs-jobs() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
ccs-jobs — view dispatch job history

Usage:
  ccs-jobs                 Recent jobs
  ccs-jobs --all           All jobs
  ccs-jobs <job-id>        Single job detail (summary + artifact paths)
  ccs-jobs <job-id> --full Single job detail with full output inlined
HELP
    return 0
  fi

  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local jobs_file="$dispatch_dir/jobs.jsonl"

  if [ ! -f "$jobs_file" ]; then
    echo "No dispatch jobs found."
    return 0
  fi

  _ccs_jobs_sync_status

  local show_all=false single_id="" full=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --all)  show_all=true ;;
      --full) full=true ;;
      "") ;;
      *)      [ -z "$single_id" ] && single_id="$arg" ;;
    esac
  done

  if [ -n "$single_id" ]; then
    _ccs_jobs_show_single "$single_id" "$full"
  else
    _ccs_jobs_show_list "$show_all"
  fi
}

_ccs_jobs_sync_status() {
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local jobs_file="$dispatch_dir/jobs.jsonl"
  [ -f "$jobs_file" ] || return 0

  local jids
  jids=$(jq -r 'select(.status=="running") | .job_id' "$jobs_file" | sort -u)

  # Which running agentpager job owns the (per-user, shared-name) tmux session:
  # the newest by created_at. The spawn guard admits at most one live worker, so
  # older running agentpager records are stale (monitor died before finalizing).
  local newest_ap_jid
  newest_ap_jid=$(jq -rs '
    group_by(.job_id) | map(reduce .[] as $r ({}; . + $r))
    | map(select(.status=="running" and .backend=="agentpager"))
    | sort_by(.created_at) | reverse | .[0].job_id // empty' "$jobs_file")

  local key="local-$(id -un)"
  local jid
  for jid in $jids; do
    # Effective status = reduce-merge (consistent with the board's show_list),
    # not tail -1 of the last raw record — a trailing fallback marker has no
    # status field and would otherwise read as null and skip this job.
    local merged status backend
    merged=$(_ccs_dispatch_jsonl_latest "$jid")
    status=$(echo "$merged" | jq -r '.status // ""')
    [ "$status" = "running" ] || continue
    backend=$(echo "$merged" | jq -r '.backend // "headless"')

    if [ "$backend" = "agentpager" ]; then
      # Defer to a live monitor: it owns startup grace (the worker's tmux session
      # appears a few seconds after dispatch), handoff detection, stop, and
      # finalize. sync must not race ahead of it — during that startup window the
      # session is legitimately absent, and finalizing here would falsely complete
      # a job that is merely starting. sync only reconciles a monitor that is gone.
      local pidfile="$dispatch_dir/pids/${jid}.pid"
      if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
        continue
      fi
      # Monitor is gone (died / never started). The worker's tmux session — not
      # the monitor pid — is now the liveness signal.
      if _ccs_dispatch_agentpager_session_alive "agent-pager-$key"; then
        [ "$jid" = "$newest_ap_jid" ] && continue   # live worker, still running
        # An older running record is stale (a newer worker owns the session). If
        # it actually finalized (md present) leave it — same deference to the
        # monitor as the session-gone branch below; otherwise reconcile.
        [ -f "$dispatch_dir/results/${jid}.md" ] && continue
        _ccs_dispatch_jsonl_append "$(jq -nc \
          --arg jid "$jid" --arg fa "$(date -Iseconds)" \
          '{job_id:$jid, status:"completed", finished_at:$fa,
            note:"superseded; monitor exited"}')"
        continue
      fi
      # Session gone. The monitor normally finalizes; if it did (md present),
      # leave it alone. If not, reconcile to completed without doing the monitor's
      # heavy finalize (stream/handoff capture) — design Q1=C keeps sync light.
      [ -f "$dispatch_dir/results/${jid}.md" ] && continue
      _ccs_dispatch_jsonl_append "$(jq -nc \
        --arg jid "$jid" --arg fa "$(date -Iseconds)" \
        '{job_id:$jid, status:"completed", finished_at:$fa,
          note:"monitor exited without finalizing; session gone"}')"
      continue
    fi

    # Headless (unchanged): the pidfile IS the worker; dead pid + no md = crash.
    local pidfile="$dispatch_dir/pids/${jid}.pid"
    if [ -f "$pidfile" ]; then
      kill -0 "$(cat "$pidfile")" 2>/dev/null && continue
    fi
    local md="$dispatch_dir/results/${jid}.md"
    [ -f "$md" ] && continue
    _ccs_dispatch_jsonl_append "$(jq -nc \
      --arg jid "$jid" \
      --arg fa "$(date -Iseconds)" \
      '{job_id:$jid, status:"failed", exit_code:-1, finished_at:$fa, summary:"process disappeared"}'
    )"
    rm -f "$pidfile"
  done
}

_ccs_jobs_show_list() {
  local show_all="$1"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local jobs_file="$dispatch_dir/jobs.jsonl"
  local limit="$CCS_DISPATCH_JOBS_LIMIT"
  local tlen="$CCS_DISPATCH_TASK_DISPLAY_LEN"

  local deduped
  deduped=$(jq -s \
    'group_by(.job_id) | map(reduce .[] as $r ({}; . + $r))
     | sort_by(.created_at) | reverse' "$jobs_file")

  if [ "$show_all" = "false" ]; then
    deduped=$(echo "$deduped" | jq ".[0:$limit]")
  fi

  local count
  count=$(echo "$deduped" | jq 'length')
  echo "Dispatch Jobs ($count)"
  echo "========================"

  echo "$deduped" | jq -r --argjson tl "$tlen" '
    .[] | "\(.job_id)  \((.backend // "?") | .[0:10] | . + " " * (10 - length))  \(.status | .[0:13] | . + " " * (13 - length))  \(.task | .[0:$tl])"
  '

  # Q2=A: last-activity footer for the newest running agentpager worker (the one
  # that owns the live tmux session). deduped is sorted created_at desc, so the
  # first running+agentpager entry is the newest.
  local running_ap
  running_ap=$(echo "$deduped" | jq -r \
    'map(select(.status=="running" and .backend=="agentpager")) | .[0].job_id // empty')
  if [ -n "$running_ap" ]; then
    _ccs_jobs_agentpager_footer "local-$(id -un)" \
      "${AGENT_PAGER_DIR:-$HOME/.agent-pager}"
  fi
}

_ccs_jobs_show_single() {
  local job_id="$1" full="${2:-false}"
  local dispatch_dir
  dispatch_dir="$(_ccs_dispatch_dir)"
  local md="$dispatch_dir/results/${job_id}.md"
  local record
  record=$(_ccs_dispatch_jsonl_latest "$job_id")

  # --full inlines the whole result md (the on-disk artifact). Default stays lean
  # so the lead's context does not grow with worker output: header fields + the
  # one-line summary + pointers to the artifacts, which the lead reads on demand.
  if [ "$full" = true ] && [ -f "$md" ]; then
    cat "$md"
  elif [ -n "$record" ]; then
    local be st proj ec created finished sum handoff_dst
    be=$(echo "$record" | jq -r '.backend // ""')
    st=$(echo "$record" | jq -r '.status // ""')
    proj=$(echo "$record" | jq -r '.project // "unknown"')
    ec=$(echo "$record" | jq -r '.exit_code // empty')
    created=$(echo "$record" | jq -r '.created_at // empty')
    finished=$(echo "$record" | jq -r '.finished_at // empty')
    sum=$(echo "$record" | jq -r '.summary // ""')

    echo "# Dispatch Job: $job_id"
    echo ""
    echo "- **Project:** $proj"
    echo "- **Status:** $st"
    [ -n "$ec" ] && echo "- **Exit code:** $ec"
    [ -n "$be" ] && echo "- **Backend:** $be"
    [ -n "$created" ] && echo "- **Created:** $created"
    [ -n "$finished" ] && echo "- **Finished:** $finished"
    local cdepth cmax cparent cstopped
    cdepth=$(echo "$record" | jq -r '.chain_depth // empty')
    if [ -n "$cdepth" ]; then
      cmax=$(echo "$record" | jq -r '.chain_max // empty')
      cparent=$(echo "$record" | jq -r '.chain_parent // empty')
      cstopped=$(echo "$record" | jq -r '.chain_stopped // empty')
      local cline="- **Chain:** depth ${cdepth}"
      [ -n "$cmax" ] && cline="${cline}/${cmax}"
      [ -n "$cparent" ] && cline="${cline}, parent=${cparent}"
      [ -n "$cstopped" ] && cline="${cline}, stopped: ${cstopped}"
      echo "$cline"
    fi
    if [ -n "$sum" ]; then
      echo ""
      echo "**Summary:** $sum"
    fi
    # Pointers, not content: the lead Reads these only when the summary is not
    # enough (design: evidence stays on disk).
    handoff_dst="$dispatch_dir/results/${job_id}.handoff"
    if [ -f "$md" ]; then
      echo ""
      echo "Full output: $md (ccs-jobs $job_id --full)"
    fi
    [ -f "$handoff_dst" ] && echo "Handoff: $handoff_dst"

    # For a still-running agent-pager worker, surface last-activity (out.stream
    # mtime) so a stalled worker is visible for a manual /stop (design D2).
    if [ "$be" = "agentpager" ] && [ "$st" = "running" ]; then
      local la
      la=$(_ccs_dispatch_agentpager_last_activity \
        "local-$(id -un)" "${AGENT_PAGER_DIR:-$HOME/.agent-pager}")
      [ -n "$la" ] && echo "Last activity: $la"
    fi
  elif [ -f "$md" ]; then
    # No jsonl record but the artifact exists: nothing structured to distill, so
    # fall back to the full md regardless of --full.
    cat "$md"
  else
    echo "Job not found: $job_id" >&2
    return 1
  fi

  # Q3=A: handoff-ready action hint (applies to both the md and record paths).
  if [ -n "$record" ]; then
    local hint_st hint_proj
    hint_st=$(echo "$record" | jq -r '.status // ""')
    hint_proj=$(echo "$record" | jq -r '.project // "."')
    _ccs_jobs_handoff_hint "$job_id" "$hint_st" "$hint_proj" "$dispatch_dir"
  fi
}

# Echo a one-line last-activity footer for the running agentpager worker so a
# stalled worker is visible on the board for a manual /stop (design D2/Q2=A).
# Single-worker MVP: at most one running agentpager worker, so one line suffices.
_ccs_jobs_agentpager_footer() {
  local key="$1" pager_dir="$2"
  local stream="$pager_dir/channels/$key/out.stream"
  if [ ! -f "$stream" ]; then
    printf '⏱ local worker: no output yet\n'
    return 0
  fi
  local mtime now idle_min iso
  mtime=$(stat -c %Y "$stream" 2>/dev/null) || return 0
  now=$(date +%s)
  idle_min=$(( (now - mtime) / 60 ))
  iso=$(date -Iseconds -d "@$mtime" 2>/dev/null)
  printf '⏱ local worker: last activity %s (%s)\n' "$iso" "$(_ccs_ago_str "$idle_min")"
}

# Echo a handoff-ready action hint: point at the captured .handoff and give a
# project-prefilled chain command. The next task can't be prefilled (it lives in
# the handoff the operator must read), and auto-chaining is v2 (design Q3=A).
_ccs_jobs_handoff_hint() {
  local job_id="$1" status="$2" project="$3" dispatch_dir="$4"
  [ "$status" = "handoff-ready" ] || return 0
  printf '\n'
  printf '→ Handoff ready: %s/results/%s.handoff\n' "$dispatch_dir" "$job_id"
  printf '  Review it, then chain the next worker:\n'
  printf '    ccs-dispatch --project %s "<next task from handoff>"\n' "$project"
  printf '  (auto-chaining is v2)\n'
}

# Generate suggested_actions for a session
# $1: session JSON object (from overview)
# Output: JSON array of actions
_ccs_dispatch_suggest_actions() {
  local session_json="$1"
  echo "$session_json" | jq '
    . as $s |
    ($s.todos // [])
    | [.[] | select(.status == "pending")]
    | if length > 0 then
        [{
          type: "dispatch",
          reason: "pending_todos",
          description: (.[0].content | .[0:80]),
          command: (
            "ccs-dispatch --project "
            + ($s.path // $s.project // ".")
            + " \""
            + .[0].content
            + "\""
          )
        }]
      else []
      end
  '
}
