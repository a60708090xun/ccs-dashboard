#!/usr/bin/env bash
# tests/test-dispatch-plan-generate.sh — validation + atomic emit
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-plan-generate-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-plan-generate"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

mkspec() { # mkspec <file> <hops-yaml-body via stdin>
  local f="$WORK/$1"; shift
  { echo "defaults:"; echo "  scope: { cwd: \"/abs/proj\" }"; echo "  executor: gemini";
    echo "hops:"; cat; } > "$f"
  echo "$f"
}

echo "=== valid spec: files land in out dir, entry is abs path, rc 0 ==="
spec="$(mkspec good.yaml <<'H'
  - id: hop1
    goal: g1
    acceptance_criteria:
      - { id: AC1, text: t, verify: { cmd: "true" } }
  - id: hop2
    goal: g2
    acceptance_criteria:
      - { id: AC1, text: t, verify: { cmd: "true" } }
H
)"
OUT="$WORK/out-good"
entry="$(_ccs_dispatch_plan_generate "$spec" "$OUT")"; rc=$?
assert_eq "generate rc 0" "0" "$rc"
assert_eq "entry is abs path" "$OUT/hop-01-hop1.task.yaml" "$entry"
assert_eq "hop2 landed" "yes" "$([ -f "$OUT/hop-02-hop2.task.yaml" ] && echo yes)"

echo "=== round-trip: every emitted file passes load_task ==="
for f in "$OUT"/hop-*.task.yaml; do
  _ccs_dispatch_gate_load_task "$f" >/dev/null 2>&1
  assert_eq "load_task accepts $(basename "$f")" "0" "$?"
done

echo "=== bad executor: no files written, rc non-zero, names offending hop ==="
bad="$(mkspec badexec.yaml <<'H'
  - id: hopA
    goal: g
    acceptance_criteria:
      - { id: AC1, text: t, verify: { cmd: "true" } }
  - id: hopB
    goal: g
    executor: wingman
    acceptance_criteria:
      - { id: AC1, text: t, verify: { cmd: "true" } }
H
)"
OUTBAD="$WORK/out-bad"
err="$(_ccs_dispatch_plan_generate "$bad" "$OUTBAD" 2>&1)"; brc=$?
assert_eq "bad-exec rc 1" "1" "$brc"
assert_eq "out dir NOT created" "no" "$([ -d "$OUTBAD" ] && echo yes || echo no)"
assert_contains "error names offending hop" "$err" "hop-02-hopB.task.yaml"

echo "=== regenerate into populated out: no stale hops, count matches ==="
spec3="$(mkspec three.yaml <<'H'
  - { id: a, goal: g, acceptance_criteria: [{ id: AC1, text: t, verify: { cmd: "true" } }] }
  - { id: b, goal: g, acceptance_criteria: [{ id: AC1, text: t, verify: { cmd: "true" } }] }
  - { id: c, goal: g, acceptance_criteria: [{ id: AC1, text: t, verify: { cmd: "true" } }] }
H
)"
OUTR="$WORK/out-regen"
_ccs_dispatch_plan_generate "$spec3" "$OUTR" >/dev/null
assert_eq "first gen has hop-03" "yes" "$([ -f "$OUTR/hop-03-c.task.yaml" ] && echo yes)"
spec2b="$(mkspec two-b.yaml <<'H'
  - { id: a, goal: g, acceptance_criteria: [{ id: AC1, text: t, verify: { cmd: "true" } }] }
  - { id: b, goal: g, acceptance_criteria: [{ id: AC1, text: t, verify: { cmd: "true" } }] }
H
)"
_ccs_dispatch_plan_generate "$spec2b" "$OUTR" >/dev/null
cnt="$(ls "$OUTR"/hop-*.task.yaml 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "regen leaves exactly 2 hops" "2" "$cnt"
assert_eq "stale hop-03 removed" "no" "$([ -f "$OUTR/hop-03-c.task.yaml" ] && echo yes || echo no)"

echo "=== all-guidance hop: rejected by load_task (line 98), no files ==="
guid="$(mkspec guid.yaml <<'H'
  - id: hopG
    goal: g
    acceptance_criteria:
      - { id: AC1, text: t, verify: { guidance: "eyeball it" } }
H
)"
OUTG="$WORK/out-guid"
_ccs_dispatch_plan_generate "$guid" "$OUTG" >/dev/null 2>&1
assert_eq "all-guidance rc 1" "1" "$?"
assert_eq "guidance out dir NOT created" "no" "$([ -d "$OUTG" ] && echo yes || echo no)"

test_summary
