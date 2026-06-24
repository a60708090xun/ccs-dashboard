#!/usr/bin/env bash
# Tests for _ccs_consume_framed_stream — agent-pager local-channel framed
# protocol parser (Stage 2). Pure unit test: no daemon/tmux/claude.
#
# Frame layout (agent-pager notify-send.sh local sink):
#   <RS>MSG<US><LABEL><RS>\n<BODY>\n<RS>END<RS>\n   (RS=0x1E, US=0x1F)
# Parser emits each frame's BODY to stdout, one per frame, newline-joined.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_DIR/ccs-dispatch.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

RS=$'\x1e'; US=$'\x1f'
# emit one frame: $1=label $2=body
frame() { printf '%sMSG%s%s%s\n%s\n%sEND%s\n' "$RS" "$US" "$1" "$RS" "$2" "$RS" "$RS"; }

test_single_frame() {
  local out; out="$(frame 'host · proj' 'hello world' | _ccs_consume_framed_stream)"
  [ "$out" = "hello world" ] && ok "single frame body extracted" \
    || bad "single frame (got: '$out')"
}

test_multi_frame() {
  local out; out="$( { frame 'h · p' 'first'; frame 'h · p' 'second'; } \
    | _ccs_consume_framed_stream )"
  [ "$out" = $'first\nsecond' ] && ok "multi frame bodies in order" \
    || bad "multi frame (got: '$out')"
}

test_body_with_newlines() {
  local out; out="$(frame 'h · p' $'line1\nline2' | _ccs_consume_framed_stream)"
  [ "$out" = $'line1\nline2' ] && ok "multiline body preserved" \
    || bad "multiline (got: '$out')"
}

test_empty_input() {
  local out; out="$(printf '' | _ccs_consume_framed_stream)"
  [ -z "$out" ] && ok "empty input -> empty output" || bad "empty (got: '$out')"
}

test_label_ignored() {
  local out; out="$(frame 'arbitrary-label-123' 'payload' | _ccs_consume_framed_stream)"
  [ "$out" = "payload" ] && ok "label ignored, body extracted" \
    || bad "label (got: '$out')"
}

test_reads_file_arg() {
  local tmp; tmp="$(mktemp "$SCRIPT_DIR/tmp.framed.XXXXXX")"
  frame 'h · p' 'from-file' > "$tmp"
  local out; out="$(_ccs_consume_framed_stream "$tmp")"
  rm -f "$tmp"
  [ "$out" = "from-file" ] && ok "reads file argument" || bad "file arg (got: '$out')"
}

run() {
  test_single_frame
  test_multi_frame
  test_body_with_newlines
  test_empty_input
  test_label_ignored
  test_reads_file_arg
  printf '\n--- %d passed, %d failed ---\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
run
