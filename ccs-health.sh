#!/usr/bin/env bash
# ccs-health.sh — Session health detection
# Sourced by ccs-dashboard.sh

# === Thresholds (env var overridable) ===
CCS_HEALTH_DUP_YELLOW="${CCS_HEALTH_DUP_YELLOW:-3}"
CCS_HEALTH_DUP_RED="${CCS_HEALTH_DUP_RED:-5}"
CCS_HEALTH_DURATION_YELLOW="${CCS_HEALTH_DURATION_YELLOW:-2880}"
CCS_HEALTH_DURATION_RED="${CCS_HEALTH_DURATION_RED:-4320}"
CCS_HEALTH_ROUNDS_YELLOW="${CCS_HEALTH_ROUNDS_YELLOW:-30}"
CCS_HEALTH_ROUNDS_RED="${CCS_HEALTH_ROUNDS_RED:-60}"
CCS_HEALTH_STALE_DAYS="${CCS_HEALTH_STALE_DAYS:-7}"
# context occupancy thresholds — 0 = disabled (informational only, not scored
# into overall). Context window size varies by model (200K vs 1M), so no
# default red line; set explicitly to enable coloring for a known model tier.
CCS_HEALTH_CONTEXT_YELLOW="${CCS_HEALTH_CONTEXT_YELLOW:-0}"
CCS_HEALTH_CONTEXT_RED="${CCS_HEALTH_CONTEXT_RED:-0}"

# ── Helper: extract health events from a JSONL session file ──
# Usage: _ccs_health_events /path/to/SESSION.jsonl
# Output: JSON object with session_id, first_ts, last_ts, prompt_count, tool_reads, tool_greps
#
# Smart duplicate counting (GH#24):
#   Rule 1: Different offset/limit on same file → not a duplicate (composite key)
#   Rule 2: Read-Edit-Read on same file → excused (not counted)
#   Rule 3: Post-compaction re-read → full weight (+2); otherwise half weight (+1)
#   Final: effective_dup = floor(weighted_sum / 2)
_ccs_health_events() {
  local f="$1"
  local sid
  sid=$(basename "$f" | sed -e 's/\.jsonl$//' -e 's/\.json$//' | cut -c1-8)

  local provider=$(_ccs_get_provider "$f")
  local pipe_cmd="cat"
  if [ "$provider" = "gemini" ]; then
    pipe_cmd="jq -c .[]"
  fi

  eval "$pipe_cmd '$f'" 2>/dev/null | jq -s --arg sid "$sid" '
    reduce .[] as $line (
      {
        first_ts: null, last_ts: null, prompt_count: 0,
        tool_reads: {}, tool_greps: {}, context_tokens: null,
        _seq: 0, _last_read_seq: {}, _last_edit_seq: {},
        _compact_seqs: [], _last_grep_seq: {},
        _dup_reads_x2: {}, _dup_greps_x2: {}
      };

      ._seq += 1 |

      # Track timestamps
      (if $line.timestamp then
        (if .first_ts == null then .first_ts = $line.timestamp else . end)
        | .last_ts = $line.timestamp
      else . end)

      # Count user prompts
      | (if $line.type == "user"
            and ($line.isMeta | not)
            and ($line.message.content | type) == "string"
         then .prompt_count += 1
         else . end)

      # Track context occupancy: last main-thread assistant message with usage
      # wins. input + cache_read + cache_creation ≈ current context tokens.
      # Skip sidechain (subagent) turns so the estimate reflects the main thread.
      | (if $line.type == "assistant" and ($line.message.usage != null)
            and ($line.isSidechain != true)
         then .context_tokens = (
                ($line.message.usage.input_tokens // 0)
                + ($line.message.usage.cache_read_input_tokens // 0)
                + ($line.message.usage.cache_creation_input_tokens // 0))
         else . end)

      # Detect compaction events
      | (if $line.type == "system" and $line.subtype == "compact_boundary"
         then ._compact_seqs += [._seq]
         else . end)

      # Process tool_use from assistant messages
      | ._seq as $cur_seq |
        (if $line.type == "assistant"
            and ($line.message.content | type) == "array"
         then
           reduce ($line.message.content[] |
                   select(.type == "tool_use")) as $tool (.;

             # Track Edit/Write for Read-Edit-Read exclusion
             if ($tool.name == "Edit" or $tool.name == "Write")
                and $tool.input.file_path
             then ._last_edit_seq[$tool.input.file_path] = $cur_seq

             # Smart Read counting
             elif $tool.name == "Read" and $tool.input.file_path then
               $tool.input.file_path as $fp |
               ($fp + "|" + ($tool.input.offset // "" | tostring)
                    + "|" + ($tool.input.limit // "" | tostring)) as $key |
               if ._last_read_seq[$key] then
                 ._last_read_seq[$key] as $prev |
                 if (._last_edit_seq[$fp] // 0) > $prev
                    and (._last_edit_seq[$fp] // 0) < $cur_seq
                 then ._last_read_seq[$key] = $cur_seq
                 else
                   ([._compact_seqs[] | select(. > $prev and . < $cur_seq)]
                    | length > 0) as $has_compact |
                   ._last_read_seq[$key] = $cur_seq |
                   if $has_compact then
                     ._dup_reads_x2[$fp] = ((._dup_reads_x2[$fp] // 0) + 2)
                   else
                     ._dup_reads_x2[$fp] = ((._dup_reads_x2[$fp] // 0) + 1)
                   end
                 end
               else ._last_read_seq[$key] = $cur_seq
               end

             # Smart Grep counting
             elif $tool.name == "Grep" and $tool.input.pattern then
               $tool.input.pattern as $pat |
               if ._last_grep_seq[$pat] then
                 ._last_grep_seq[$pat] as $prev |
                 ([._compact_seqs[] | select(. > $prev and . < $cur_seq)]
                  | length > 0) as $has_compact |
                 ._last_grep_seq[$pat] = $cur_seq |
                 if $has_compact then
                   ._dup_greps_x2[$pat] = ((._dup_greps_x2[$pat] // 0) + 2)
                 else
                   ._dup_greps_x2[$pat] = ((._dup_greps_x2[$pat] // 0) + 1)
                 end
               else ._last_grep_seq[$pat] = $cur_seq
               end

             else . end
           )
         else . end)
    )
    # Replace raw counts with effective dup counts
    | .tool_reads = (._dup_reads_x2
        | with_entries(.value = ((.value / 2) | floor))
        | with_entries(select(.value > 0)))
    | .tool_greps = (._dup_greps_x2
        | with_entries(.value = ((.value / 2) | floor))
        | with_entries(select(.value > 0)))
    | del(._seq, ._last_read_seq, ._last_edit_seq,
          ._compact_seqs, ._last_grep_seq,
          ._dup_reads_x2, ._dup_greps_x2)
    | .session_id = $sid
  ' "$f"
}

# ── Helper: score health indicators from event JSON ──
# Usage: _ccs_health_events "$f" | _ccs_health_score
# Input:  event JSON via stdin
# Output: scored JSON with overall level and per-indicator details
_ccs_health_score() {
  jq \
    --argjson dup_y "${CCS_HEALTH_DUP_YELLOW}" \
    --argjson dup_r "${CCS_HEALTH_DUP_RED}" \
    --argjson dur_y "${CCS_HEALTH_DURATION_YELLOW}" \
    --argjson dur_r "${CCS_HEALTH_DURATION_RED}" \
    --argjson rnd_y "${CCS_HEALTH_ROUNDS_YELLOW}" \
    --argjson rnd_r "${CCS_HEALTH_ROUNDS_RED}" \
    --argjson ctx_y "${CCS_HEALTH_CONTEXT_YELLOW:-0}" \
    --argjson ctx_r "${CCS_HEALTH_CONTEXT_RED:-0}" \
    '
    # dup_tool: max count across tool_reads and tool_greps
    def max_val:
      [.[] // 0] | if length == 0 then 0
      else max end;

    def classify($v; $y; $r):
      if $v >= $r then "red"
      elif $v >= $y then "yellow"
      else "green" end;

    # context indicator: informational. Each line applies only when its own
    # threshold is > 0, so a red-only or yellow-only config still has a green
    # tier. Disabled (info) when both thresholds are off or the value is absent.
    def classify_ctx($v; $y; $r):
      if $v == null then "info"
      elif ($y <= 0) and ($r <= 0) then "info"
      elif ($r > 0) and ($v >= $r) then "red"
      elif ($y > 0) and ($v >= $y) then "yellow"
      else "green" end;

    def severity:
      if . == "red" then 2
      elif . == "yellow" then 1
      else 0 end;

    def worst($a; $b):
      if ($a | severity) >= ($b | severity) then $a
      else $b end;

    (.tool_reads | max_val) as $rd_max |
    (.tool_greps | max_val) as $gr_max |
    ([$rd_max, $gr_max] | max) as $dup_val |

    # duration in minutes
    # strip optional milliseconds (.123) before parsing
    def parse_ts: sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;

    (if .first_ts == null or .last_ts == null then 0
     else
       ( (.last_ts | parse_ts) - (.first_ts | parse_ts)
       ) / 60 | floor
     end) as $dur_val |

    .prompt_count as $rnd_val |
    (.context_tokens // null) as $ctx_val |

    classify($dup_val; $dup_y; $dup_r) as $dup_lv |
    classify($dur_val; $dur_y; $dur_r) as $dur_lv |
    classify($rnd_val; $rnd_y; $rnd_r) as $rnd_lv |
    classify_ctx($ctx_val; $ctx_y; $ctx_r) as $ctx_lv |

    # context is informational: it never feeds overall (context window size is
    # model-dependent, so it must not distort the health verdict/sort)
    worst($dup_lv; worst($dur_lv; $rnd_lv)) as $overall |

    {
      session_id: .session_id,
      overall: $overall,
      indicators: {
        dup_tool: {
          level: $dup_lv,
          value: $dup_val,
          threshold: { yellow: $dup_y, red: $dup_r }
        },
        duration: {
          level: $dur_lv,
          value: $dur_val,
          unit: "min",
          threshold: { yellow: $dur_y, red: $dur_r }
        },
        rounds: {
          level: $rnd_lv,
          value: $rnd_val,
          threshold: { yellow: $rnd_y, red: $rnd_r }
        },
        context: {
          level: $ctx_lv,
          value: $ctx_val,
          unit: "tokens",
          threshold: { yellow: $ctx_y, red: $ctx_r }
        }
      }
    }
    '
}

# ── Helper: single-char colored badge for a session ──
# Usage: _ccs_health_badge /path/to/SESSION.jsonl
# Output: colored ● (green) / ◐ (yellow) / ○ (red)
_ccs_health_badge() {
  local f="$1"
  local level
  level=$(_ccs_health_events "$f" | _ccs_health_score | jq -r '.overall')
  case "$level" in
    green)  printf '\033[32m●\033[0m';;
    yellow) printf '\033[33m◐\033[0m';;
    red)    printf '\033[31m○\033[0m';;
    *)      printf '?';;
  esac
}

# ── Helper: emoji badge for a session (Markdown output) ──
# Usage: _ccs_health_badge_md /path/to/SESSION.jsonl
# Output: 🟢 / 🟡 / 🔴
_ccs_health_badge_md() {
  local f="$1"
  local level
  level=$(_ccs_health_events "$f" | _ccs_health_score | jq -r '.overall')
  case "$level" in
    green)  echo '🟢';;
    yellow) echo '🟡';;
    red)    echo '🔴';;
    *)      echo '⚪';;
  esac
}

# ── ccs-health — session health report command ──
# Usage: ccs-health [session-id-prefix] [--md] [--json]
ccs-health() {
  local prefix="" fmt="terminal" show_all=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --md)   fmt="md"; shift ;;
      --json) fmt="json"; shift ;;
      --all)  show_all=true; shift ;;
      --help|-h)
        cat <<'HELP'
ccs-health — session health report

Usage: ccs-health [prefix] [--md|--json] [--all]

Options:
  prefix    Session ID prefix to filter
  --md      Markdown output
  --json    JSON output
  --all     Show all sessions (include stale)
  --help    Show this help

Sessions older than $CCS_HEALTH_STALE_DAYS days
(default 7) are shown as a stale summary.
Use --all to expand details.

Indicators:
  dup_tool   Max effective duplicate tool calls
  duration   Session duration (minutes)
  rounds     User prompt count
  context    Est. context occupancy from last assistant message
             usage (input+cache_read+cache_creation). Informational;
             set CCS_HEALTH_CONTEXT_YELLOW/RED (tokens) to color it.
HELP
        return 0
        ;;
      *) prefix="$1"; shift ;;
    esac
  done

  # Allow override for testing
  local projects_dir="${CCS_PROJECTS_DIR:-$HOME/.claude/projects}"

  # Collect active JSONL files
  local files=()
  while IFS= read -r -d '' f; do
    # Skip archived sessions
    if _ccs_is_archived "$f"; then
      continue
    fi
    # If prefix given, filter by session ID
    if [ -n "$prefix" ]; then
      local bname
      bname=$(basename "$f" | sed -e 's/\.jsonl$//' -e 's/\.json$//')
      if [[ "$bname" != "${prefix}"* ]]; then
        continue
      fi
    fi
    files+=("$f")
  done < <(find "$projects_dir" \
    -maxdepth 2 \( -name "*.jsonl" -o -name "*.json" \) -type f \
    ! -path "*/subagents/*" \
    -print0 2>/dev/null)

  # Build crash lookup to exclude crashed sessions
  local -A _health_crash_map=()
  if type _ccs_detect_crash &>/dev/null; then
    local -a _health_projects=()
    local _hf
    for _hf in "${files[@]}"; do
      _health_projects+=("$(_ccs_resolve_project_path "$(basename "$(dirname "$_hf")")" 2>/dev/null)")
    done
    _ccs_detect_crash _health_crash_map files _health_projects 2>/dev/null
  fi

  # Process each session: collect scored JSON
  local results=()
  local f
  for f in "${files[@]}"; do
    # Skip crashed sessions — health report is meaningless for dead sessions
    local _h_sid
    _h_sid=$(basename "$f" | sed -e 's/\.jsonl$//' -e 's/\.json$//')
    if [ -n "${_health_crash_map[$_h_sid]+x}" ] && [[ "${_health_crash_map[$_h_sid]}" == high:* ]]; then
      continue
    fi
    local events scored project topic encoded_dir
    events=$(_ccs_health_events "$f")

    # Skip empty sessions (no real user prompts)
    local pc
    pc=$(echo "$events" | jq -r '.prompt_count')
    [ "$pc" = "0" ] && continue

    scored=$(echo "$events" | _ccs_health_score)

    # Extract project name
    encoded_dir=$(basename "$(dirname "$f")")
    if type _ccs_friendly_project_name \
      &>/dev/null; then
      project=$(\
        _ccs_friendly_project_name \
        "$encoded_dir" 2>/dev/null)
    fi
    [ -z "$project" ] && \
      project="$encoded_dir"

    # Extract topic
    if type _ccs_topic_from_jsonl \
      &>/dev/null; then
      topic=$(\
        _ccs_topic_from_jsonl "$f" 2>/dev/null)
    fi
    [ -z "$topic" ] && topic="-"

    # Get last_ts from events for sorting
    local last_ts
    last_ts=$(echo "$events" \
      | jq -r '.last_ts // ""')

    # Determine if session is stale
    local is_stale=false
    if [ -n "$last_ts" ]; then
      local last_epoch now_epoch stale_secs
      last_epoch=$(date -d "${last_ts%.*}Z" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      stale_secs=$((CCS_HEALTH_STALE_DAYS * 86400))
      [ $((now_epoch - last_epoch)) -gt $stale_secs ] && is_stale=true
    fi

    # Enrich scored JSON with project/topic/last_ts/stale
    scored=$(echo "$scored" | jq \
      --arg proj "$project" \
      --arg topic "$topic" \
      --arg last_ts "$last_ts" \
      --argjson stale "$is_stale" \
      '. + {project: $proj, topic: $topic,
            last_ts: $last_ts, stale: $stale}')

    results+=("$scored")
  done

  # Combine into JSON array and sort
  # Sort: red(2) > yellow(1) > green(0),
  # then by last_ts descending
  local combined
  if [ ${#results[@]} -eq 0 ]; then
    combined="[]"
  else
    combined=$(printf '%s\n' "${results[@]}" \
      | jq -s '
      def sev:
        if .overall == "red" then 2
        elif .overall == "yellow" then 1
        else 0 end;
      sort_by([-(sev),
               (.last_ts | explode | map(-.)) ])
    ')
  fi

  # Split into recent and stale
  local recent stale
  recent=$(echo "$combined" | jq '[.[] | select(.stale != true)]')
  stale=$(echo "$combined" | jq '[.[] | select(.stale == true)]')
  local stale_count
  stale_count=$(echo "$stale" | jq 'length')

  # ── Output ──
  case "$fmt" in
    json)
      echo "$combined" | jq '.'
      ;;

    md)
      echo "## Session Health Report"
      echo ""
      local md_src="$recent"
      if $show_all; then md_src="$combined"; fi
      if [ "$(echo "$md_src" \
        | jq 'length')" = "0" ] \
        && [ "$stale_count" = "0" ]; then
        echo "(no active sessions)"
        return 0
      fi
      echo "$md_src" | jq -r \
        --arg red "🔴" \
        --arg yel "🟡" \
        --arg grn "🟢" '
        def badge:
          if .overall == "red" then $red
          elif .overall == "yellow" then $yel
          else $grn end;
        def ibadge($lv):
          if $lv == "red" then $red
          elif $lv == "yellow" then $yel
          else $grn end;
        def cbadge($lv):
          if $lv == "red" then $red
          elif $lv == "yellow" then $yel
          elif $lv == "green" then $grn
          else "⚪" end;
        def fmt_ctx($v):
          if $v == null then "-"
          else "~" + (($v / 1000) | floor | tostring) + "k" end;
        .[] |
        "### " + badge + " "
          + .session_id
          + " \u2014 " + .project,
        "- **Topic:** " + .topic,
        "- dup_tool: "
          + ibadge(.indicators.dup_tool.level)
          + " "
          + (.indicators.dup_tool.value
             | tostring),
        "- duration: "
          + ibadge(.indicators.duration.level)
          + " "
          + (.indicators.duration.value
             | tostring)
          + "m",
        "- rounds: "
          + ibadge(.indicators.rounds.level)
          + " "
          + (.indicators.rounds.value
             | tostring),
        "- context: "
          + cbadge(.indicators.context.level)
          + " "
          + fmt_ctx(.indicators.context.value),
        ""
      '
      # Stale summary
      if ! $show_all && [ "$stale_count" -gt 0 ]; then
        local stale_red stale_yellow
        stale_red=$(echo "$stale" | jq '[.[] | select(.overall == "red")] | length')
        stale_yellow=$(echo "$stale" | jq '[.[] | select(.overall == "yellow")] | length')
        echo "---"
        echo ""
        echo "*${stale_count} stale sessions (>${CCS_HEALTH_STALE_DAYS}d): 🔴 ${stale_red} 🟡 ${stale_yellow} — use \`--all\` to expand*"
      fi
      ;;

    terminal|*)
      printf "\033[1mSession Health Report\033[0m\n"
      printf "═══════════════════════\n\n"
      local term_src="$recent"
      if $show_all; then term_src="$combined"; fi
      if [ "$(echo "$term_src" \
        | jq 'length')" = "0" ] \
        && [ "$stale_count" = "0" ]; then
        printf "  \033[90m(no active sessions)\033[0m\n"
        return 0
      fi
      echo "$term_src" | jq -r '.[] |
        [.overall,
         .session_id,
         .project,
         .topic,
         .indicators.dup_tool.level,
         (.indicators.dup_tool.value
          | tostring),
         .indicators.duration.level,
         (.indicators.duration.value
          | tostring),
         .indicators.rounds.level,
         (.indicators.rounds.value
          | tostring),
         .indicators.context.level,
         (.indicators.context.value
          | tostring)
        ] | @tsv
      ' | while IFS=$'\t' read -r \
          overall sid proj topic \
          dup_lv dup_v \
          dur_lv dur_v \
          rnd_lv rnd_v \
          ctx_lv ctx_v; do

        # Overall badge with color
        local badge color reset
        reset='\033[0m'
        case "$overall" in
          green)
            badge="●"
            color='\033[32m' ;;
          yellow)
            badge="◐"
            color='\033[33m' ;;
          red)
            badge="○"
            color='\033[31m' ;;
          *)
            badge="?"
            color='' ;;
        esac

        printf "${color}${badge}${reset}"
        printf " %s  %s\n" "$sid" "$proj"
        printf "  Topic: %s\n" "$topic"

        # Indicator line helpers
        _health_ibadge() {
          case "$1" in
            green)
              printf '\033[32m●\033[0m' ;;
            yellow)
              printf '\033[33m◐\033[0m' ;;
            red)
              printf '\033[31m○\033[0m' ;;
          esac
        }

        printf "  dup_tool: "
        _health_ibadge "$dup_lv"
        printf " %-4s" "$dup_v"
        printf "  duration: "
        _health_ibadge "$dur_lv"
        printf " %sm\n" "$dur_v"

        printf "  rounds:   "
        _health_ibadge "$rnd_lv"
        printf " %s\n" "$rnd_v"

        # context occupancy (informational; dim dot when disabled/absent)
        local ctx_badge ctx_disp
        case "$ctx_lv" in
          green)  ctx_badge='\033[32m●\033[0m' ;;
          yellow) ctx_badge='\033[33m◐\033[0m' ;;
          red)    ctx_badge='\033[31m○\033[0m' ;;
          *)      ctx_badge='\033[90m·\033[0m' ;;
        esac
        if [ "$ctx_v" = "null" ]; then
          ctx_disp="-"
        else
          ctx_disp="~$((ctx_v / 1000))k"
        fi
        printf "  context:  "
        printf '%b' "$ctx_badge"
        printf " %s\n" "$ctx_disp"
        echo
      done

      # Stale summary
      if ! $show_all && [ "$stale_count" -gt 0 ]; then
        local stale_red stale_yellow
        stale_red=$(echo "$stale" | jq '[.[] | select(.overall == "red")] | length')
        stale_yellow=$(echo "$stale" | jq '[.[] | select(.overall == "yellow")] | length')
        printf "\033[90m── %d stale sessions (>%dd):" "$stale_count" "$CCS_HEALTH_STALE_DAYS"
        printf " \033[31m○\033[90m %d" "$stale_red"
        printf "  \033[33m◐\033[90m %d" "$stale_yellow"
        printf "  — use --all to expand\033[0m\n\n"
      fi

      printf "Legend: "
      printf "\033[32m●\033[0m green  "
      printf "\033[33m◐\033[0m yellow  "
      printf "\033[31m○\033[0m red\n"
      ;;
  esac
}
