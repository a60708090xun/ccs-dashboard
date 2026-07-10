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

# argv-recording shims for both CLIs, earlier on PATH than the real ones
BIN="$WORK/bin"; mkdir -p "$BIN"
for c in claude gemini; do
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
