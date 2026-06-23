#!/usr/bin/env bash
# ccs-failure-triage.sh — Model-failure (confabulation-family) quick triage
# Sourced by ccs-dashboard.sh

# === Thresholds (env var overridable) ===
CCS_FAILURE_LONG_TURN_MS="${CCS_FAILURE_LONG_TURN_MS:-600000}"   # 10 min
CCS_FAILURE_MULTI_SEG_MIN="${CCS_FAILURE_MULTI_SEG_MIN:-2}"       # min text-segs per turn to flag

# === SOP path (resolved at source time) ===
_CCS_FAILURE_SOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/docs/failure-triage.md"

# ── Helper: run 5-check Python triage, write markdown to stdout ──
# Usage: _ccs_failure_run_checks <transcript-path>
_ccs_failure_run_checks() {
  local tr="$1"
  local long_turn_ms="${CCS_FAILURE_LONG_TURN_MS}"
  local multi_seg_min="${CCS_FAILURE_MULTI_SEG_MIN}"
  local sop_path="${_CCS_FAILURE_SOP}"

  python3 - "$tr" "$long_turn_ms" "$multi_seg_min" "$sop_path" <<'PY'
import json, os, re, sys
from collections import Counter

TR           = sys.argv[1]
LONG_TURN_MS = int(sys.argv[2])
MULTI_SEG_MIN = int(sys.argv[3])
SOP_PATH     = sys.argv[4]

records = []
with open(TR) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

def text_blocks(o):
    msg = o.get('message') or {}
    c = msg.get('content')
    out = []
    if isinstance(c, str):
        return [('text', c)]
    if isinstance(c, list):
        for it in c:
            if not isinstance(it, dict):
                continue
            t = it.get('type')
            if t == 'text':
                out.append(('text', it.get('text', '')))
            elif t == 'thinking':
                out.append(('thinking', it.get('thinking', '')))
            elif t == 'tool_use':
                inp = json.dumps(it.get('input', {}), ensure_ascii=False)
                out.append(('tool_use', f"{it.get('name')} {inp}"))
            elif t == 'tool_result':
                cc = it.get('content')
                if isinstance(cc, str):
                    out.append(('tool_result', cc))
                elif isinstance(cc, list):
                    for k in cc:
                        if isinstance(k, dict) and isinstance(k.get('text'), str):
                            out.append(('tool_result', k['text']))
    return out

def is_real_user_prompt(o):
    """True if this user record is a genuine prompt, not a tool_result
    or harness-injected meta record."""
    if o.get('type') != 'user':
        return False
    msg = o.get('message') or {}
    c = msg.get('content')
    if isinstance(c, list):
        for it in c:
            if isinstance(it, dict) and it.get('type') == 'tool_result':
                return False
    txt_parts = [b[1] for b in text_blocks(o) if b[0] == 'text']
    t = '\n'.join(txt_parts).strip()
    if not t:
        return False
    if t.startswith('<local-command-caveat>'):
        return False
    if t.startswith('<local-command-stdout>'):
        return False
    if t.startswith('<command-name>'):
        return False
    if t.startswith('Launching skill:'):
        return False
    if t.startswith('Base directory for this skill:'):
        return False
    if t.startswith('Tool ran without output'):
        return False
    return True

# ============================================================
# Check 1: Model & session shape
# ============================================================
print("# Model-failure triage report")
print()
print(f"**Transcript:** `{TR}`")
print(f"**Records:** {len(records)}")
print()
print("## 1. Model & session shape")
print()

models = Counter()
for o in records:
    if o.get('type') == 'assistant':
        m = (o.get('message') or {}).get('model')
        if m:
            models[m] += 1

if models:
    print("Model versions seen (assistant.message.model):")
    print()
    print("```")
    for m, n in models.most_common():
        print(f"{m}  count={n}")
    print("```")
    flag_48 = any('opus-4-8' in m or 'opus-4.8' in m for m in models)
    if flag_48:
        print()
        print("> ⚠ Opus 4.8 present — confabulation-family risk elevated "
              "(per case studies + anthropics/claude-code#63884).")
else:
    print("> ⚠ No model version recorded — transcript may be incomplete.")

first_ts = next((o.get('timestamp') for o in records if o.get('timestamp')), None)
last_ts = None
for o in records:
    ts = o.get('timestamp')
    if ts:
        last_ts = ts

turn_durations = []
for o in records:
    if o.get('type') == 'system' and o.get('subtype') == 'turn_duration':
        d = o.get('durationMs') or 0
        turn_durations.append((d, o.get('timestamp')))
turn_durations.sort(reverse=True)

print()
print("Window:")
print()
print("```")
print(f"first    {first_ts}")
print(f"last     {last_ts}")
if turn_durations:
    print(f"turns    {len(turn_durations)} (with stop_hook_summary)")
    top = turn_durations[0]
    print(f"longest  {top[0]/1000:.1f}s  ending  {top[1]}")
print("```")

if turn_durations and turn_durations[0][0] > LONG_TURN_MS:
    print()
    print("> ⚠ Long turn detected (> 10 min) — drift / confabulation risk "
          "elevated. See SOP Phase 1 Check 3.")

# ============================================================
# Check 2: User prompt history
# ============================================================
print()
print("## 2. User prompt history (real prompts only)")
print()
print("Excludes `<local-command-caveat>`, skill-launch records, "
      "tool_result records.")
print()
user_prompts = []
for o in records:
    if is_real_user_prompt(o):
        txt = '\n'.join(b[1] for b in text_blocks(o) if b[0] == 'text').strip()
        user_prompts.append((o.get('timestamp') or '(no-ts)', txt))

if not user_prompts:
    print("> ⚠ No real user prompts found.")
else:
    print(f"Total: **{len(user_prompts)}**")
    print()
    print("```")
    for ts, txt in user_prompts:
        first = txt.splitlines()[0][:120]
        print(f"{ts}  {first}")
    print("```")
    print()
    print("> Cross-reference this list against any assistant prose that says")
    print("> \"直接誠實回答你的問題:X\" / \"先回答:Y\" / \"answering your")
    print("> question about Z\" — if no prompt contains that question, it's")
    print("> imagined (Sub-pattern A).")

# ============================================================
# Check 3: Multi-text-segment turns
# ============================================================
print()
print("## 3. Multi-text-segment turns (same turn, multiple assistant text "
      "blocks, no user prompt in between)")
print()

# Walk records, segment by real user prompt
turns = []   # list of lists of (ts, type, kind, snippet)
cur = []
for o in records:
    if is_real_user_prompt(o):
        if cur:
            turns.append(cur)
        cur = []
    cur.append(o)
if cur:
    turns.append(cur)

flagged_turns = []
for ti, t in enumerate(turns):
    text_segs = []
    for o in t:
        if o.get('type') != 'assistant':
            continue
        for kind, body in text_blocks(o):
            if kind == 'text' and body.strip():
                first = body.strip().splitlines()[0][:140]
                text_segs.append((o.get('timestamp'), first))
    if len(text_segs) >= MULTI_SEG_MIN:
        first_user = next(((o.get('timestamp'),
                            '\n'.join(b[1] for b in text_blocks(o)
                                      if b[0] == 'text').strip().splitlines()[0][:80])
                           for o in t if is_real_user_prompt(o)),
                          (None, '(no user prompt in this segment)'))
        flagged_turns.append((first_user, text_segs))

if not flagged_turns:
    print("None. (All turns have ≤ 1 assistant text segment.)")
else:
    print(f"**{len(flagged_turns)} turn(s)** with multiple assistant text "
          "segments — strong signal for Sub-pattern A/D.")
    print()
    for (uts, uprompt), segs in flagged_turns:
        print(f"### Turn after user [{uts}]")
        print()
        print(f"User prompt: `{uprompt}`")
        print()
        print(f"Assistant text segments ({len(segs)}):")
        print()
        print("```")
        for ts, first in segs:
            print(f"  [{ts}] {first}")
        print("```")
        print()

# ============================================================
# Check 4: Self-correction / apology phrasing red flags
# ============================================================
print()
print("## 4. Self-correction / apology phrasing red flags")
print()

# Compile patterns. Each pattern is (label, regex)
PATTERNS = [
    ('zh:讓你久等/讓你等了',           r'讓你[久等]+等?了?抱歉|讓你等了'),
    ('zh:直接誠實回答你的問題',         r'直接誠實回答你的問題'),
    ('zh:先回答:X 是猜測還是',          r'先回答[::].{0,30}是猜測還是'),
    ('zh:修正:我之前',                  r'修正[::].{0,5}我之前'),
    ('zh:石沉大海/沒被喚醒',            r'石沉大海|沒被喚醒'),
    ('en:I need to stop and be honest',  r'I need to stop and be honest'),
    ('en:Let me get the ground truth',   r'Let me get the ground truth'),
    ('en:prose run ahead',               r'prose (?:run|running) ahead'),
    ('en:fabricated',                    r'fabricated|I fabricated'),
    ('en:nonce / poisoning / injection', r'nonce|tool poisoning|prompt injection|被污染|tampered'),
]

hits_by_pattern = {label: [] for label, _ in PATTERNS}
for o in records:
    if o.get('type') != 'assistant':
        continue
    for kind, body in text_blocks(o):
        if kind != 'text':
            continue
        for label, pat in PATTERNS:
            if re.search(pat, body):
                first = body.strip().splitlines()[0][:120]
                hits_by_pattern[label].append((o.get('timestamp'), first))

any_hit = False
for label, hits in hits_by_pattern.items():
    if hits:
        any_hit = True
        print(f"### `{label}` — {len(hits)} hit(s)")
        print()
        print("```")
        for ts, first in hits[:10]:
            print(f"  [{ts}] {first}")
        if len(hits) > 10:
            print(f"  ... +{len(hits)-10} more")
        print("```")
        print()

if not any_hit:
    print("None.")
elif any('nonce' in label or 'poisoning' in label or 'injection' in label
         for label, hits in hits_by_pattern.items() if hits):
    print("> ⚠ Externalized-blame phrasing detected — Sub-pattern C very "
          "likely. See SOP Phase 2 Sub-pattern C.")

# ============================================================
# Check 5: Narrative vs tool_use divergence
# ============================================================
print()
print("## 5. Narrative vs tool_result divergence")
print()
print("Items claimed in `assistant.text` that have no matching evidence "
      "in any `tool_result`.")
print()

# Collect strings from assistant.text vs from tool_result
HASH_RE = re.compile(r'\b[a-f0-9]{7,40}\b')
PR_RE = re.compile(r'(?:pull|PR)\s*/?\s*#?(\d{1,5})\b', re.IGNORECASE)
PATH_RE = re.compile(r'(?:/|~/)[\w./\-]+')

def collect(records, sources):
    """Return dict of {pattern_name: set(values)} for the given sources."""
    out = {'hash': set(), 'pr': set(), 'path': set()}
    for o in records:
        if o.get('type') == 'assistant' and 'assistant' in sources:
            for kind, body in text_blocks(o):
                if kind == 'text':
                    for h in HASH_RE.findall(body):
                        out['hash'].add(h)
                    for n in PR_RE.findall(body):
                        out['pr'].add(n)
                    for p in PATH_RE.findall(body):
                        out['path'].add(p)
        if o.get('type') == 'user' and 'tool_result' in sources:
            for kind, body in text_blocks(o):
                if kind == 'tool_result':
                    for h in HASH_RE.findall(body):
                        out['hash'].add(h)
                    for n in PR_RE.findall(body):
                        out['pr'].add(n)
                    for p in PATH_RE.findall(body):
                        out['path'].add(p)
    return out

claimed = collect(records, {'assistant'})
evidence = collect(records, {'tool_result'})

# Filter hashes: keep only ones that LOOK like git hashes (7-40 hex,
# but exclude common false positives like UUIDs and message IDs).
def likely_git_hash(h):
    return 7 <= len(h) <= 40 and re.fullmatch(r'[a-f0-9]+', h) is not None

# Suspicious = claimed in assistant.text but NOT in tool_result
divergence = {
    k: sorted(claimed[k] - evidence[k]) for k in claimed
}

# Hash filter: only flag short-ish ones (real git hashes are usually
# shown as 7-12 hex; longer matches often UUID fragments / not hashes
# we care about)
divergence['hash'] = [h for h in divergence['hash']
                     if likely_git_hash(h) and len(h) <= 12]

print(f"- **Commit-hash-like strings** claimed but no tool_result evidence: "
      f"{len(divergence['hash'])}")
if divergence['hash']:
    print("```")
    for h in divergence['hash'][:20]:
        print(f"  {h}")
    if len(divergence['hash']) > 20:
        print(f"  ... +{len(divergence['hash'])-20} more")
    print("```")
    print("> Verify with `git -C <repo> cat-file -t <hash>`. "
          "`missing object` = fabricated. Sub-pattern B.")
    print()

print(f"- **PR numbers** claimed but no tool_result evidence: "
      f"{len(divergence['pr'])}")
if divergence['pr']:
    print("```")
    for n in divergence['pr'][:20]:
        print(f"  #{n}")
    if len(divergence['pr']) > 20:
        print(f"  ... +{len(divergence['pr'])-20} more")
    print("```")
    print("> Verify with `gh pr view <N> --repo <owner/repo>`. "
          "`Could not resolve` = fabricated. Sub-pattern B.")
    print()

# Path divergence is high false-positive; only flag if path appears
# in narrative-positive context AND nowhere in tool_result.
suspicious_paths = [p for p in divergence['path']
                    if not p.startswith('/usr/')
                    and not p.startswith('/etc/')
                    and not p.startswith('/var/')
                    and not p.startswith('/proc/')
                    and 'node_modules' not in p
                    and len(p) > 8]

print(f"- **File paths** mentioned but not in tool_result: "
      f"{len(suspicious_paths)} (after filtering)")
if suspicious_paths and len(suspicious_paths) <= 30:
    print("```")
    for p in suspicious_paths[:30]:
        print(f"  {p}")
    print("```")
    print("> Verify with `ls <path>`. Note: many of these are "
          "intentionally-mentioned paths (docs, examples), not fabrications. "
          "Only flag if assistant claims write/read on the path.")

# ============================================================
# Summary / verdict
# ============================================================
print()
print("## Summary")
print()

signals = []
if any('opus-4-8' in m for m in models):
    signals.append("Opus 4.8 (high-risk model)")
if turn_durations and turn_durations[0][0] > LONG_TURN_MS:
    signals.append(
        f"long turn (longest {turn_durations[0][0]/1000:.0f}s)")
if flagged_turns:
    signals.append(
        f"multi-text-segment turn x{len(flagged_turns)} (Sub-pattern A/D)")
if any(hits_by_pattern[lbl]
       for lbl in hits_by_pattern):
    signals.append("self-correction phrasing detected")
if divergence['hash'] or divergence['pr']:
    signals.append("narrative-vs-tool_result divergence (Sub-pattern B)")
if any(hits_by_pattern[lbl]
       for lbl in hits_by_pattern
       if 'nonce' in lbl or 'poisoning' in lbl or 'injection' in lbl):
    signals.append("externalized blame (Sub-pattern C)")

if not signals:
    print("**No confabulation signals detected.** Likely not a "
          "model-failure case — investigate harness / pager / MCP / env.")
else:
    print("**Signals detected:**")
    print()
    for s in signals:
        print(f"- {s}")
    print()
    print("**Next step:** SOP Phase 2 — pick the matching sub-pattern, "
          "expand the suspicious turn manually, verify items against "
          "git / gh / fs ground truth.")
    print()
    print(f"SOP: `{SOP_PATH}`")
PY
}

# ── Helper: resolve transcript path from bare session id ──
# Usage: _ccs_failure_resolve_sid <session-id>
# Prints: full path to the transcript JSONL
_ccs_failure_resolve_sid() {
  local sid="$1"
  local proj_root slug tr
  proj_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  slug="$(echo "$proj_root" | sed 's|/|-|g')"
  tr="$HOME/.claude/projects/${slug}/${sid}.jsonl"
  if [ ! -r "$tr" ]; then
    echo "ERROR: transcript not found:" >&2
    echo "  $tr" >&2
    echo >&2
    echo "Project root: $proj_root" >&2
    echo "Slug:         $slug" >&2
    echo >&2
    echo "Did you cd to the right project? Or is the session id correct?" >&2
    echo "List candidates:" >&2
    echo "  ls ~/.claude/projects/${slug}/*.jsonl 2>/dev/null | head" >&2
    echo >&2
    echo "Or pass a label instead: ccs-failure-triage <hint>:<6-hex>" >&2
    return 1
  fi
  echo "$tr"
}

# ── Helper: resolve transcript path and project root from label ──
# Usage: _ccs_failure_resolve_label <hint>:<6-hex>
# Prints: <transcript-path>:<project-root>  (colon-separated)
_ccs_failure_resolve_label() {
  local label="$1"
  local short="${label##*:}"
  local matches=()
  shopt -s nullglob
  matches=( "$HOME"/.claude/projects/*/"${short}"*.jsonl )
  shopt -u nullglob
  if [ ${#matches[@]} -eq 0 ]; then
    echo "ERROR: no transcript found for label '$label'" >&2
    echo "  Searched: ~/.claude/projects/*/${short}*.jsonl" >&2
    echo >&2
    echo "Possible reasons:" >&2
    echo "  - Session is on a different host (multi-host setup)" >&2
    echo "  - Short prefix typo (label format is <hint>:<6-hex>)" >&2
    echo "  - Transcript directory pruned" >&2
    return 1
  fi
  if [ ${#matches[@]} -gt 1 ]; then
    echo "ERROR: short prefix '$short' is ambiguous, matches multiple:" >&2
    printf "  %s\n" "${matches[@]}" >&2
    echo >&2
    echo "Use the full session id instead." >&2
    return 1
  fi
  local tr="${matches[0]}"
  local proj_root
  proj_root="$(python3 - "$tr" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except json.JSONDecodeError: continue
        cwd = o.get('cwd')
        if isinstance(cwd, str) and cwd:
            print(cwd); break
PY
)"
  if [ -z "$proj_root" ]; then
    proj_root="$(pwd)"
    echo "WARN: transcript has no cwd field, using current dir as project root: $proj_root" >&2
  fi
  echo "${tr}:${proj_root}"
}

# ── ccs-failure-triage — model-failure triage command ──
# Usage:
#   ccs-failure-triage <session-id>        bare sid mode
#   ccs-failure-triage <hint>:<6-hex>      label mode
#   ccs-failure-triage --help / -h         show usage
#   ccs-failure-triage --sop               print path to SOP doc
ccs-failure-triage() {
  local arg="${1:-}"

  case "$arg" in
    --help|-h)
      cat <<'HELP'
ccs-failure-triage — confabulation-family quick triage

Usage:

  # Bare session-id (cd to the project root first)
  cd /path/to/project
  ccs-failure-triage <session-id>

  # Label (no cd needed; project resolved from transcript metadata)
  ccs-failure-triage <hint>:<6-hex-short>
  # e.g. myproject:4623ae, argus:873960

Bare session-id mode:
  Resolves the transcript at:
    ~/.claude/projects/<slug>/<session-id>.jsonl
  where <slug> is the current project root with `/` replaced by `-`.
  Project root auto-detected via `git rev-parse --show-toplevel`,
  falls back to pwd if not in a git repo.

Label mode:
  Glob-locates the transcript via the 6-hex short prefix:
    ~/.claude/projects/*/<short>*.jsonl
  Project root is read from the transcript's first `cwd` field.

Writes the report to:
  <project>/tmp/<session-id>-triage-<YYYY-MM-DD>.md

Companion SOP:
  See: ccs-failure-triage --sop

Options:
  --help, -h   Show this help
  --sop        Print path to the companion SOP document

Env vars:
  CCS_FAILURE_LONG_TURN_MS    Long-turn threshold in ms (default: 600000)
  CCS_FAILURE_MULTI_SEG_MIN   Min text-segments per turn to flag (default: 2)
HELP
      return 0
      ;;

    --sop)
      echo "$_CCS_FAILURE_SOP"
      return 0
      ;;

    "")
      echo "Usage: ccs-failure-triage <session-id> | <hint>:<6-hex> | --help | --sop" >&2
      return 1
      ;;
  esac

  command -v python3 >/dev/null || {
    echo "ERROR: python3 required" >&2
    return 2
  }

  local tr proj_root sid input_mode

  if [[ "$arg" == *:* ]]; then
    # Label mode
    input_mode="label"
    local label_result
    label_result="$(_ccs_failure_resolve_label "$arg")" || return 1
    tr="${label_result%%:*}"
    proj_root="${label_result#*:}"
    sid="$(basename "$tr" .jsonl)"
  else
    # Bare session-id mode
    input_mode="sid"
    sid="$arg"
    proj_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    tr="$(_ccs_failure_resolve_sid "$sid")" || return 1
  fi

  local out_dir out
  out_dir="${proj_root}/tmp"
  out="${out_dir}/${sid}-triage-$(date +%Y-%m-%d).md"
  mkdir -p "$out_dir"

  echo "Input mode:    $input_mode"
  echo "Session id:    $sid"
  echo "Project root:  $proj_root"
  echo "Transcript:    $tr"
  echo

  _ccs_failure_run_checks "$tr" > "$out"

  echo "Wrote: $out"
  echo
  echo "Summary (last section of the report):"
  echo "---"
  sed -n '/^## Summary/,$p' "$out"
}
