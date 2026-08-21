#!/usr/bin/env bash
# tests/test-dispatch-executor-cli.sh — worker spawns the selected CLI
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export XDG_DATA_HOME="$SCRIPT_DIR/tmp/test-dispatch-executor-cli-xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"
source "$SCRIPT_DIR/tests/fixture-helper.sh"
source "$SCRIPT_DIR/ccs-dashboard.sh"

WORK="$SCRIPT_DIR/tmp/test-dispatch-executor-cli"
rm -rf "$WORK"; mkdir -p "$WORK"; _TEST_DIRS+=("$WORK")

# argv-recording shims, earlier on PATH than the real ones
BIN="$WORK/bin"; mkdir -p "$BIN"
for c in claude gemini grok; do
  cat > "$BIN/$c" <<EOF
#!/usr/bin/env bash
echo "$c \$*" >> "$WORK/argv.log"
EOF
  chmod +x "$BIN/$c"
done
export PATH="$BIN:$PATH"

CWD="$WORK/repo"; mkdir -p "$CWD"; (cd "$CWD" && git init -q)
RUN="$WORK/run"; mkdir -p "$RUN"

echo "=== gemini executor spawns gemini -p ... --approval-mode yolo ==="
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do X" "$RUN" 1 60 gemini
log="$(cat "$WORK/argv.log")"
assert_contains "gemini binary invoked" "$log" "gemini -p do X"
assert_contains "gemini approval-mode yolo" "$log" "--approval-mode yolo"
assert_not_contains "gemini did not call claude" "$log" "claude -p"

echo "=== omitted executor spawns claude -p ==="
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do Y" "$RUN" 2 60
log2="$(cat "$WORK/argv.log")"
assert_contains "claude binary invoked" "$log2" "claude -p do Y"
assert_not_contains "claude default did not call gemini" "$log2" "gemini -p"

echo "=== declared model is pinned per CLI (headless) ==="
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do Z" "$RUN" 1 60 gemini "" headless "gemini-3.5-flash"
log_gm="$(cat "$WORK/argv.log")"
assert_contains "gemini gets -m" "$log_gm" "-m gemini-3.5-flash"

: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do Z" "$RUN" 1 60 claude "" headless "haiku"
log_cm="$(cat "$WORK/argv.log")"
assert_contains "claude gets --model" "$log_cm" "--model haiku"
assert_not_contains "claude does not get gemini's flag" "$log_cm" "-m haiku"

echo "=== no model declared -> no model flag ==="
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do W" "$RUN" 1 60 gemini
log_nom="$(cat "$WORK/argv.log")"
assert_not_contains "gemini keeps its own default" "$log_nom" " -m "
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do W" "$RUN" 1 60 claude
assert_not_contains "claude keeps its own default" "$(cat "$WORK/argv.log")" "--model"

echo "=== grok executor spawns grok -p ... --always-approve --output-format plain ==="
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do G" "$RUN" 1 60 grok
log_gk="$(cat "$WORK/argv.log")"
assert_contains "grok binary invoked" "$log_gk" "grok -p do G"
assert_contains "grok always-approve" "$log_gk" "--always-approve"
assert_contains "grok output-format plain" "$log_gk" "--output-format plain"
assert_not_contains "grok did not call claude" "$log_gk" "claude -p"
assert_not_contains "grok did not call gemini" "$log_gk" "gemini -p"

echo "=== grok model pin / omit ==="
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do G" "$RUN" 1 60 grok "" headless "grok-4.6"
assert_contains "grok gets -m" "$(cat "$WORK/argv.log")" "-m grok-4.6"
: > "$WORK/argv.log"
_ccs_dispatch_run_worker "$CWD" "do G" "$RUN" 1 60 grok
# Exact argv, not " -m ": an empty `cmd+=(-m "$model")` logs a trailing
# `-m` with no following space, which the substring miss would still pass.
assert_eq "grok omit model exact argv" \
  "grok -p do G --always-approve --output-format plain" \
  "$(cat "$WORK/argv.log")"

test_summary

