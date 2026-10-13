#!/usr/bin/env bash
# tests/test-dispatch-ac-lint.sh — advisory AC lint for hand-computed literals
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-ac-lint-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-ac-lint"; rm -rf "$WORK"
mkdir -p "$WORK/repo"; _TEST_DIRS+=("$WORK")

# en_US.UTF-8 decides the collation-dependent cases; skip them when absent.
HAVE_EN=no
locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$' && HAVE_EN=yes

# task_json <cmd>: a one-AC task whose verify.cmd is <cmd>.
task_json() {
  jq -n --arg c "$1" \
    '{id:"t1", goal:"g", acceptance_criteria:[{id:"AC1", text:"t", verify:{cmd:$c}}]}'
}

# lint_err <cmd> [env assignments...]: run the lint under a controlled locale
# and echo its stderr. Locale vars are cleared first so the caller's shell does
# not leak into the verdict.
lint_err() {
  local cmd="$1"; shift
  ( unset LC_ALL LC_COLLATE LANG
    for kv in "$@"; do export "$kv"; done
    _ccs_dispatch_ac_lint "$(task_json "$cmd")" 2>&1 >/dev/null )
}

rule_of() { # rule_of <stderr>: the rule label of the first lint line, or none
  local r
  r="$(printf '%s\n' "$1" | grep -oE ': AC_(SORT_ORDER|LITERAL_SET):' | head -1 | tr -d ': ')"
  echo "${r:-none}"
}

echo "=== U1: unsorted literal behind plain sort -> AC_SORT_ORDER ==="
e="$(lint_err "test \"\$(git diff --name-only | sort | tr '\\n' ' ')\" = 'b.sh a.sh '" LC_ALL=C)"
assert_eq "U1 rule" "AC_SORT_ORDER" "$(rule_of "$e")"
assert_contains "U1 names task/ac" "$e" "AC lint (advisory): t1/AC1:"

echo "=== U2: C-ordered literal under en_US gate -> AC_SORT_ORDER with recompute ==="
if [ "$HAVE_EN" = yes ]; then
  e="$(lint_err "test \"\$(git diff --name-only | sort | tr '\\n' ' ')\" = 'B.txt README.md a.sh'" LC_ALL=en_US.UTF-8)"
  assert_eq "U2 rule" "AC_SORT_ORDER" "$(rule_of "$e")"
  assert_contains "U2 shows recomputed order" "$e" "a.sh B.txt README.md"
  assert_contains "U2 states the premise" "$e" "exactly one token"
  assert_contains "U2 scopes the claim to the comparison" "$e" "this comparison can never be true"
else
  echo "  SKIP: U2 (en_US.UTF-8 locale not installed)"
fi

C_ORDER="'B.txt README.md a.sh'"
echo "=== U3*: locale overrides ==="
if [ "$HAVE_EN" = yes ]; then
  e="$(lint_err "test \"\$(ls | LC_ALL=C sort | tr '\\n' ' ')\" = $C_ORDER" LC_ALL=en_US.UTF-8)"
  assert_eq "U3 sort-prefix LC_ALL=C degrades" "AC_LITERAL_SET" "$(rule_of "$e")"
  e="$(lint_err "test \"\$(ls | env LC_COLLATE=C sort | tr '\\n' ' ')\" = $C_ORDER" LANG=en_US.UTF-8)"
  assert_eq "U3b env LC_COLLATE=C degrades" "AC_LITERAL_SET" "$(rule_of "$e")"
  e="$(lint_err "export LC_ALL=C; test \"\$(ls | sort | tr '\\n' ' ')\" = $C_ORDER" LC_ALL=en_US.UTF-8)"
  assert_eq "U3c export before the comparison degrades" "AC_LITERAL_SET" "$(rule_of "$e")"
  e="$(lint_err "test \"\$(ls | LANG=C sort | tr '\\n' ' ')\" = $C_ORDER" LANG=en_US.UTF-8)"
  assert_eq "U3e sort-prefix LANG=C degrades" "AC_LITERAL_SET" "$(rule_of "$e")"
  # The literal is in the GATE's order and the override (C) would make it look
  # unsorted: an AC that sets its own locale is never judged deterministically.
  EN_ORDER="'a.sh B.txt README.md'"
  e="$(lint_err "test \"\$(ls | LC_ALL=C sort | tr '\\n' ' ')\" = $EN_ORDER" LC_ALL=en_US.UTF-8)"
  assert_eq "U3p sort-prefix override is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"
  e="$(lint_err "test \"\$(ls | env LC_COLLATE=C sort | tr '\\n' ' ')\" = $EN_ORDER" LANG=en_US.UTF-8)"
  assert_eq "U3bp env LC_COLLATE override is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"
  e="$(lint_err "export LC_ALL=C; test \"\$(ls | sort | tr '\\n' ' ')\" = $EN_ORDER" LC_ALL=en_US.UTF-8)"
  assert_eq "U3cp export override is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"
  e="$(lint_err "test \"\$(ls | LANG=C sort | tr '\\n' ' ')\" = $EN_ORDER" LANG=en_US.UTF-8)"
  assert_eq "U3ep LANG override is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"
  # Elsewhere-positioned assignment must not be applied: the gate (C) PASSes
  # 'B a', so applying en_US would wrongly claim AC_SORT_ORDER.
  e="$(lint_err "LC_ALL=en_US.UTF-8 true && test \"\$(printf 'B\\na\\n' | sort | tr '\\n' ' ')\" = 'B a '" LC_ALL=C)"
  assert_eq "U3d elsewhere assignment is not applied" "AC_LITERAL_SET" "$(rule_of "$e")"
else
  echo "  SKIP: U3/U3b/U3c/U3e/U3*p/U3d (en_US.UTF-8 locale not installed)"
fi
# ...and must degrade rather than fall back to the gate locale: under C the
# literal 'a B' looks unsorted, so a non-degrading lint would say AC_SORT_ORDER.
e="$(lint_err "LC_ALL=C true && test \"\$(printf 'B\\na\\n' | sort | tr '\\n' ' ')\" = 'a B'" LC_ALL=C)"
assert_eq "U3d2 elsewhere assignment degrades to suspect" "AC_LITERAL_SET" "$(rule_of "$e")"

echo "=== U4: multi-token literal without sort -> AC_LITERAL_SET ==="
e="$(lint_err "test \"\$(cat f)\" = 'x y'" LC_ALL=C)"
assert_eq "U4 rule" "AC_LITERAL_SET" "$(rule_of "$e")"

echo "=== U5: shapes outside the rules -> no line ==="
assert_eq "U5 single token" "" "$(lint_err "test \"\$(wc -l < f)\" = '3'" LC_ALL=C)"
assert_eq "U5 no comparison" "" "$(lint_err "grep -q foo f" LC_ALL=C)"
assert_eq "U5 != comparison" "" "$(lint_err "test \"\$(ls | sort | tr '\\n' ' ')\" != 'b a'" LC_ALL=C)"

echo "=== U6: sort with other options -> not AC_SORT_ORDER ==="
e="$(lint_err "test \"\$(ls | sort -k1 | tr '\\n' ' ')\" = 'b a'" LC_ALL=C)"
assert_eq "U6 sort -k1" "AC_LITERAL_SET" "$(rule_of "$e")"
e="$(lint_err "test \"\$(ls | sort -r | tr '\\n' ' ')\" = 'b a'" LC_ALL=C)"
assert_eq "U6b sort -r" "AC_LITERAL_SET" "$(rule_of "$e")"

echo "=== U7: correctly sorted literal with a trailing space -> AC_LITERAL_SET ==="
e="$(lint_err "test \"\$(ls | sort | tr '\\n' ' ')\" = 'a.sh b.sh '" LC_ALL=C)"
assert_eq "U7 rule" "AC_LITERAL_SET" "$(rule_of "$e")"

echo "=== U8: advisory only -- rc 0 and nothing on stdout ==="
o="$( (unset LC_ALL LC_COLLATE LANG; export LC_ALL=C
       _ccs_dispatch_ac_lint "$(task_json "test \"\$(ls | sort | tr '\\n' ' ')\" = 'b a'")" 2>/dev/null) )"; rc=$?
assert_eq "U8 rc 0 on a hit" "0" "$rc"
assert_eq "U8 stdout empty" "" "$o"

echo "=== U9: json only on hits ==="
J="$WORK/u9-hit.json"
( export LC_ALL=C; _ccs_dispatch_ac_lint "$(task_json "test \"\$(ls | sort | tr '\\n' ' ')\" = 'b a'")" "$J" 2>/dev/null )
assert_eq "U9 advisory flag" "true" "$(jq -r '.advisory' "$J" 2>/dev/null)"
assert_eq "U9 rule recorded" "AC_SORT_ORDER" "$(jq -r '.hits[0].rule' "$J" 2>/dev/null)"
assert_eq "U9 recomputed recorded" "a b" "$(jq -r '.hits[0].recomputed' "$J" 2>/dev/null)"
J2="$WORK/u9-miss.json"
( export LC_ALL=C; _ccs_dispatch_ac_lint "$(task_json "true")" "$J2" 2>/dev/null )
assert_eq "U9 no hit -> no file" "no" "$([ -e "$J2" ] && echo yes || echo no)"

echo "=== U10: lint failure is visible and still rc 0 ==="
e="$( (python3() { return 1; }
       _ccs_dispatch_ac_lint "$(task_json "true")") 2>&1 >/dev/null )"; rc=$?
assert_eq "U10 rc 0" "0" "$rc"
assert_contains "U10 says skipped" "$e" "AC lint skipped"

echo "=== U11: non-whitelisted stage after sort -> not AC_SORT_ORDER ==="
e="$(lint_err "test \"\$(ls | sort | uniq -c | tr '\\n' ' ')\" = '2 b 1 a'" LC_ALL=C)"
assert_eq "U11 uniq -c" "AC_LITERAL_SET" "$(rule_of "$e")"
e="$(lint_err "test \"\$(ls | sort | xargs -n1 basename | tr '\\n' ' ')\" = 'z.sh a.sh'" LC_ALL=C)"
assert_eq "U11 xargs -n1 basename" "AC_LITERAL_SET" "$(rule_of "$e")"

echo "=== U12: whitelisted stages after sort -> AC_SORT_ORDER ==="
e="$(lint_err "test \"\$(ls | sort | paste -sd' ')\" = 'b a'" LC_ALL=C)"
assert_eq "U12 paste -sd' '" "AC_SORT_ORDER" "$(rule_of "$e")"
e="$(lint_err "test \"\$(ls | sort | head -n 2 | xargs)\" = 'b a'" LC_ALL=C)"
assert_eq "U12 head -n 2 | xargs" "AC_SORT_ORDER" "$(rule_of "$e")"

echo "=== U13: tr that rewrites token text -> not AC_SORT_ORDER ==="
e="$(lint_err "test \"\$(ls | sort | tr a-z A-Z | tr '\\n' ' ')\" = 'B A'" LC_ALL=C)"
assert_eq "U13 tr a-z A-Z" "AC_LITERAL_SET" "$(rule_of "$e")"

echo "=== U14: comparison shapes ==="
e="$(lint_err "[ 'b a' = \"\$(ls | sort | xargs)\" ]" LC_ALL=C)"
assert_eq "U14 literal on the left" "AC_SORT_ORDER" "$(rule_of "$e")"
e="$(lint_err "[[ \"\$(ls | sort | xargs)\" == 'b a' ]]" LC_ALL=C)"
assert_eq "U14 == operator" "AC_SORT_ORDER" "$(rule_of "$e")"
e="$(lint_err "test \"\$(cd sub && ls | sort | xargs)\" = 'b a'" LC_ALL=C)"
assert_eq "U14 cd prefix keeps the pipeline" "AC_SORT_ORDER" "$(rule_of "$e")"
e="$(lint_err "test \"\$(ls | sort | paste -sd ' ')\" = 'b a'" LC_ALL=C)"
assert_eq "U14 paste -sd with a separate operand" "AC_SORT_ORDER" "$(rule_of "$e")"
assert_eq "U14 comparison inside a quoted pattern is not one" "" \
  "$(lint_err "grep -qF '[ \"\$(ls | sort)\" = \"b a\" ]' script.sh" LC_ALL=C)"

echo "=== U15: sort -u collapses duplicate tokens ==="
e="$(lint_err "test \"\$(ls | sort -u | xargs)\" = 'a a b'" LC_ALL=C)"
assert_eq "U15 sort -u with a duplicate" "AC_SORT_ORDER" "$(rule_of "$e")"
assert_contains "U15 recompute drops the duplicate" "$e" "as 'a b'"

echo "=== U16: locale mentions that cannot be trusted degrade to suspect ==="
# Gate C; the literal 'a B' looks unsorted under C, so any rule that trusted
# the mention (or ignored it without degrading) would say AC_SORT_ORDER.
P="test \"\$(printf 'B\\na\\n' | sort | tr '\\n' ' ')\" = 'a B '"
for pre in "unset LC_ALL; " "(export LC_ALL=C); " "false && export LC_ALL=C; " \
           "test -n \"\$(export LC_ALL=C; echo x)\" && " "export LC_ALL=C & " \
           "if true; then export LC_ALL=C; fi; "; do
  e="$(lint_err "$pre$P" LC_ALL=C)"
  assert_eq "U16 [$pre]" "AC_LITERAL_SET" "$(rule_of "$e")"
done
# Newline-separated branch: the export is a statement of its own, so only the
# compound-keyword guard keeps it from being trusted.
e="$(lint_err "if false
then
export LC_ALL=C
fi
$P" LC_ALL=C)"
assert_eq "U16 export on its own line inside if" "AC_LITERAL_SET" "$(rule_of "$e")"
e="$(lint_err "test \"\$(export LC_ALL=C; printf 'B\\na\\n' | sort | tr '\\n' ' ')\" = 'a B '" LC_ALL=C)"
assert_eq "U16 export inside the substitution" "AC_LITERAL_SET" "$(rule_of "$e")"

echo "=== U18: shapes the delta review found trusted or dropped ==="
# Gate C with literal 'a B ' (see U16): trusting any of these exports, or
# judging the comparison as deterministic at all, would say AC_SORT_ORDER.
for pre in "true ||
export LC_ALL=C
" "cat >/dev/null <<'EOF'
export LC_ALL=C
EOF
" "(true
export LC_ALL=C
); " "echo \$'x\\'; export LC_ALL=C; y' #'
"; do
  e="$(lint_err "$pre$P" LC_ALL=C)"
  assert_eq "U18 untrusted [${pre%%$'\n'*}]" "AC_LITERAL_SET" "$(rule_of "$e")"
done
e="$(lint_err "test \"\$(printf 'B\\na\\n' & true | sort | tr '\\n' ' ')\" = 'a B '" LC_ALL=C)"
assert_eq "U18 & inside the substitution" "AC_LITERAL_SET" "$(rule_of "$e")"
e="$(lint_err "test \"\$(printf 'B\\na\\n'
true | sort | tr '\\n' ' ')\" = 'a B '" LC_ALL=C)"
assert_eq "U18 newline inside the substitution" "AC_LITERAL_SET" "$(rule_of "$e")"
# Comparisons in a subshell or a nested substitution are still reported, only
# never as the deterministic rule.
e="$(lint_err "(cd . && test \"\$(ls | sort | xargs)\" = 'b a')" LC_ALL=C)"
assert_eq "U18 comparison in a subshell" "AC_LITERAL_SET" "$(rule_of "$e")"
e="$(lint_err "x=\$(test \"\$(ls | sort | xargs)\" = 'b a' && echo ok); test -n \"\$x\"" LC_ALL=C)"
assert_eq "U18 comparison in a nested substitution" "AC_LITERAL_SET" "$(rule_of "$e")"
if [ "$HAVE_EN" = yes ]; then
  # A newline-separated top-level export is not trusted either: en_US would make
  # 'B a' look unsorted, but the rule only ever uses the gate's own locale.
  e="$(lint_err "export LC_ALL=en_US.UTF-8
test \"\$(printf 'B\\na\\n' | sort | tr '\\n' ' ')\" = 'B a '" LC_ALL=C)"
  assert_eq "U18 newline-separated export is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"
else
  echo "  SKIP: U18 newline-separated export (en_US.UTF-8 locale not installed)"
fi

echo "=== U19: nothing in front is trusted (delta review 2, option C) ==="
# Gate C, export LC_ALL=C (same as the gate) and literal 'a B ': trusting the
# export would say AC_SORT_ORDER; every shape must degrade to AC_LITERAL_SET.
X="export LC_ALL=C"
for pre in "v=\${v%% #*}; (
$X
)
" "true || # note
$X
" "true |&
$X
" "x=\$(cat <<'EOF'
)
$X
EOF
)
" "(true)# ; $X
"; do
  e="$(lint_err "$pre$P" LC_ALL=C)"
  assert_eq "U19 untrusted [${pre%%$'\n'*}]" "AC_LITERAL_SET" "$(rule_of "$e")"
done
e="$(lint_err "$X
$X; $P" LC_ALL=C)"
assert_eq "U19 a run of pure exports is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"
# Recall: shapes the comment / ANSI-C handling must not swallow.
e="$(lint_err "v=\${v%% #*}; test \"\$(ls | sort | xargs)\" = 'b a'" LC_ALL=C)"
assert_eq "U19 # inside \${...} is not a comment" "AC_LITERAL_SET" "$(rule_of "$e")"
e="$(lint_err "echo \$\$'a\\'; test \"\$(ls | sort | xargs)\" = 'b a'" LC_ALL=C)"
assert_eq "U19 \$\$ before a quote is not ANSI-C" "AC_LITERAL_SET" "$(rule_of "$e")"
assert_eq "U19 comparison inside a comment is not one" "" \
  "$(lint_err "true; # test \"\$(ls | sort | xargs)\" = 'b a'" LC_ALL=C)"
assert_eq "U19 comparison inside \$'...' is not one" "" \
  "$(lint_err "printf \$'[ \"\$(ls | sort)\" = \"b a\" ]'" LC_ALL=C)"

# A heredoc body is text: a comparison written there is never judged
# deterministic, and a heredoc in a substitution counts too (documented scope).
e="$(lint_err "cat >f <<'EOF'
test \"\$(ls | sort | xargs)\" = 'b a'
EOF" LC_ALL=C)"
assert_eq "U19 comparison in a heredoc body is not deterministic" "AC_LITERAL_SET" "$(rule_of "$e")"
e="$(lint_err "x=\$(cat <<'EOF'
hi
EOF
); test \"\$(ls | sort | xargs)\" = 'b a'" LC_ALL=C)"
assert_eq "U19 heredoc inside a substitution blocks the rule" "AC_LITERAL_SET" "$(rule_of "$e")"
assert_eq "U19 escaped quote inside \$'...' keeps it one string" "" \
  "$(lint_err "printf \$'it\\'s [ \"\$(ls | sort)\" = \"b a\" ]'" LC_ALL=C)"

echo "=== U20: deterministic only with nothing in front (delta review 3, option C) ==="
# Same trusted/untrusted probe as U19 ($X, $P, gate C).
for pre in "$(printf '\v')$X
" "$(printf '\xc2\xa0')$X
" "export LC_ALL=\"C\"
" "$(printf 'export\vLC_ALL=C')
"; do
  e="$(lint_err "$pre$P" LC_ALL=C)"
  assert_eq "U20 untrusted export [$(printf '%q' "${pre%%$'\n'*}")]" "AC_LITERAL_SET" "$(rule_of "$e")"
done
# Any other command in front, or in the comparison's own statement, could
# change what sort sees -- no locale mention needed to block the rule.
S="test \"\$(ls | sort | xargs)\" = 'b a'"
for pre in ". ./f.sh; " "eval x=1; " "true; " "true && " "sort() { :; }; "; do
  e="$(lint_err "$pre$S" LC_ALL=C)"
  assert_eq "U20 [$pre] in front" "AC_LITERAL_SET" "$(rule_of "$e")"
done
e="$(lint_err "! $S" LC_ALL=C)"
assert_eq "U20 negated test head is still judged" "AC_SORT_ORDER" "$(rule_of "$e")"
e="$(lint_err "$X; $S" LC_ALL=C)"
assert_eq "U20 pure export in front is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"
assert_eq "U20 # after a subshell ) is a comment" "" \
  "$(lint_err "(true)# $S" LC_ALL=C)"
e="$(lint_err "echo \$(true)# $S" LC_ALL=C)"
assert_eq "U20 # after a substitution ) is not a comment" "AC_LITERAL_SET" "$(rule_of "$e")"

# The approved scope: any other locale mention, and a heredoc anywhere in
# the code, still block the rule even where they could not reach this sort.
for c in "test \"\$(ls | LC_ALL=C cat | sort | xargs)\" = 'b a'" \
         "$S && unset LC_ALL" \
         "$S; cat >f <<'EOF'
x
EOF" \
         "$S; x=\$(cat <<'EOF'
hi
EOF
)"; do
  e="$(lint_err "$c" LC_ALL=C)"
  assert_eq "U20 blocked [$(printf '%q' "${c:0:50}")]" "AC_LITERAL_SET" "$(rule_of "$e")"
done

echo "=== U21: operand boundaries and non-locale assignments (delta review 4) ==="
# Text glued to an operand makes it something other than the literal; the
# comparison is still reported, never as the deterministic rule.
for c in "test \"\$(printf 'ab\\nac\\n' | sort | xargs)\" = 'ab a'c" \
         "test 'b a' = \"\$(printf 'b\\n' | sort | xargs)\"' a'" \
         "export PATH=bin; $S" \
         "test \"\$(ls | PATH=bin sort | xargs)\" = 'b a'" \
         "test \"\$(ls | sort | PATH=bin xargs)\" = 'b a'" \
         "test -n x && $S" \
         "[ x = y ] || [ \"\$(ls | sort | xargs)\" = 'b a' ]"; do
  e="$(lint_err "$c" LC_ALL=C)"
  assert_eq "U21 [$(printf '%q' "${c:0:60}")]" "AC_LITERAL_SET" "$(rule_of "$e")"
done
# A tab-indented locale export in front is not trusted either.
e="$(lint_err "$(printf '\t')$X
$P" LC_ALL=C)"
assert_eq "U21 tab-indented export is not trusted" "AC_LITERAL_SET" "$(rule_of "$e")"

# Option C literal: any locale name anywhere, and a prefix assignment on any
# pipeline stage (even before the sort), block the rule.
for c in "$S && unset LANG" "$S && unset LC_COLLATE" \
         "test \"\$(X=1 printf 'b\\na\\n' | sort | xargs)\" = 'b a'"; do
  e="$(lint_err "$c" LC_ALL=C)"
  assert_eq "U21 option C [$(printf '%q' "${c:0:50}")]" "AC_LITERAL_SET" "$(rule_of "$e")"
done
# F3: only ASCII blanks separate literal tokens (shell and xargs agree).
e="$(lint_err "test \"\$(ls | sort | xargs)\" = '$(printf 'b\xc2\xa0a')'" LC_ALL=C)"
assert_eq "U21 NBSP does not split a literal token" "" "$(rule_of "$e" | sed 's/none//')"
assert_eq "U21 premise names leading blanks and quotes" "yes" \
  "$(lint_err "test \"\$(ls | sort | xargs)\" = 'b a'" LC_ALL=C | grep -q 'no leading blank, quote or backslash' && echo yes)"

echo "=== U17: json records the collation the recompute used ==="
J3="$WORK/u17.json"
( unset LC_ALL LC_COLLATE; export LANG=C.UTF-8
  _ccs_dispatch_ac_lint "$(task_json "test \"\$(ls | sort | xargs)\" = 'b a'")" "$J3" 2>/dev/null )
assert_eq "U17 rule under the gate locale" "AC_SORT_ORDER" "$(jq -r '.hits[0].rule' "$J3" 2>/dev/null)"
assert_eq "U17 collation is the gate's" "C.UTF-8" "$(jq -r '.hits[0].collation' "$J3" 2>/dev/null)"

# ── Integration: the production call sites ──
_ccs_dispatch_run_worker() {
  local run_dir="$3" attempt="$4"
  # Record whether the lint had already written its file when the worker spawned.
  [ -f "$run_dir/ac-lint.json" ] && echo yes >> "$WORK/lint-before-spawn" \
    || echo no >> "$WORK/lint-before-spawn"
  mkdir -p "$run_dir/attempt-$(printf '%02d' "$attempt")"; return 0
}
HIT_AC="test \"\$(printf 'a b')\" = 'a b'"
mk() { # mk <file> <id> <cmd> [next]
  { printf 'id: %s\ngoal: g\nscope: { cwd: "%s" }\n' "$2" "$WORK/repo"
    [ -n "${4:-}" ] && printf 'next: %s\n' "$4"
    printf 'acceptance_criteria:\n  - id: AC1\n    text: t\n    verify:\n      cmd: %s\n' \
      "$(jq -Rn --arg c "$3" '$c')"
  } > "$1"
}

echo "=== I1: single hop with a lint hit -> unchanged outcome, lint on stderr ==="
mk "$WORK/s1.yaml" s1 "$HIT_AC"
rm -f "$WORK/lint-before-spawn"
out="$(ccs-dispatch-run "$WORK/s1.yaml" 2>"$WORK/i1.err")"; rc=$?
err="$(cat "$WORK/i1.err")"
run_dir="$(printf '%s\n' "$out" | sed -n 's/^run: //p')"
assert_eq "I1 exit 0" "0" "$rc"
assert_contains "I1 outcome accepted" "$out" "outcome: accepted"
assert_not_contains "I1 no stop reason" "$out" "stop="
assert_eq "I1 chain stop_reason" "empty-next" "$(jq -r '.stop_reason' "$run_dir/chain.json" 2>/dev/null)"
assert_contains "I1 lint line on stderr" "$err" "AC lint (advisory): s1/AC1: AC_LITERAL_SET:"
assert_eq "I1 ac-lint.json in hop dir" "yes" \
  "$(ls "$run_dir"/hop-01-*/ac-lint.json >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "I1 lint ran before the worker spawned" "yes" "$(cat "$WORK/lint-before-spawn" 2>/dev/null)"

echo "=== I2: both hops hit, chain still runs both and lints each ==="
mk "$WORK/c1.yaml" c1 "$HIT_AC" c2.yaml
mk "$WORK/c2.yaml" c2 "$HIT_AC"
out="$(ccs-dispatch-run "$WORK/c1.yaml" 2>/dev/null)"; rc=$?
run_dir="$(printf '%s\n' "$out" | sed -n 's/^run: //p')"
assert_eq "I2 exit 0" "0" "$rc"
assert_eq "I2 two hops ran" "2" "$(jq -r '.hops | length' "$run_dir/chain.json" 2>/dev/null)"
assert_eq "I2 hop-02 dir exists" "yes" \
  "$(ls -d "$run_dir"/hop-02-* >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "I2 hop-01 ac-lint.json" "yes" \
  "$(ls "$run_dir"/hop-01-*/ac-lint.json >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "I2 hop-02 ac-lint.json" "yes" \
  "$(ls "$run_dir"/hop-02-*/ac-lint.json >/dev/null 2>&1 && echo yes || echo no)"

echo "=== I3: ccs-dispatch-plan lints each hop, stdout stays the entry path ==="
{ echo "defaults:"; echo "  scope: { cwd: \"$WORK/repo\" }"
  echo "hops:"
  echo "  - id: p1"; echo "    goal: g"
  echo "    acceptance_criteria:"
  echo "      - id: AC1"; echo "        text: t"
  echo "        verify:"; echo "          cmd: $(jq -Rn --arg c "$HIT_AC" '$c')"
  echo "  - id: p2"; echo "    goal: g"
  echo "    acceptance_criteria:"
  echo "      - id: AC1"; echo "        text: t"
  echo "        verify:"; echo "          cmd: $(jq -Rn --arg c "$HIT_AC" '$c')"
} > "$WORK/spec.yaml"
out="$(ccs-dispatch-plan "$WORK/spec.yaml" --out "$WORK/plan-out" 2>"$WORK/i3.err")"; rc=$?
assert_eq "I3 exit 0" "0" "$rc"
assert_eq "I3 stdout is one line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "I3 stdout is the entry path" "$WORK/plan-out/hop-01-p1.task.yaml" "$out"
assert_contains "I3 lint line for hop 1" "$(cat "$WORK/i3.err")" "AC lint (advisory): p1/AC1: AC_LITERAL_SET:"
assert_contains "I3 lint line for hop 2" "$(cat "$WORK/i3.err")" "AC lint (advisory): p2/AC1: AC_LITERAL_SET:"

test_summary
