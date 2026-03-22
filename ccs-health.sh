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

# ── Helper: extract health events from a JSONL session file ──
# Usage: _ccs_health_events /path/to/SESSION.jsonl
# Output: JSON object with session_id, first_ts, last_ts, prompt_count, tool_reads, tool_greps
_ccs_health_events() {
  local f="$1"
  local sid
  sid=$(basename "$f" .jsonl | cut -c1-8)

  jq -s --arg sid "$sid" '
    # Build initial accumulator
    reduce .[] as $line (
      {
        first_ts: null,
        last_ts: null,
        prompt_count: 0,
        tool_reads: {},
        tool_greps: {}
      };

      # Track timestamps
      (if $line.timestamp then
        (if .first_ts == null then .first_ts = $line.timestamp else . end)
        | .last_ts = $line.timestamp
      else . end)

      # Count user prompts (type=user, content is string, not isMeta)
      | (if $line.type == "user"
            and ($line.isMeta | not)
            and ($line.message.content | type) == "string"
         then .prompt_count += 1
         else . end)

      # Count tool_use from assistant messages
      | (if $line.type == "assistant"
            and ($line.message.content | type) == "array"
         then
           reduce ($line.message.content[] |
                   select(.type == "tool_use")) as $tool (.;
             if $tool.name == "Read" and $tool.input.file_path then
               .tool_reads[$tool.input.file_path] =
                 ((.tool_reads[$tool.input.file_path] // 0) + 1)
             elif $tool.name == "Grep" and $tool.input.pattern then
               .tool_greps[$tool.input.pattern] =
                 ((.tool_greps[$tool.input.pattern] // 0) + 1)
             else .
             end
           )
         else . end)
    )
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
    '
    # dup_tool: max count across tool_reads and tool_greps
    def max_val:
      [.[] // 0] | if length == 0 then 0
      else max end;

    def classify($v; $y; $r):
      if $v >= $r then "red"
      elif $v >= $y then "yellow"
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

    classify($dup_val; $dup_y; $dup_r) as $dup_lv |
    classify($dur_val; $dur_y; $dur_r) as $dur_lv |
    classify($rnd_val; $rnd_y; $rnd_r) as $rnd_lv |

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
  local prefix="" fmt="terminal"
  while [ $# -gt 0 ]; do
    case "$1" in
      --md)   fmt="md"; shift ;;
      --json) fmt="json"; shift ;;
      --help|-h)
        cat <<'HELP'
ccs-health — session health report

Usage: ccs-health [prefix] [--md|--json]

Options:
  prefix    Session ID prefix to filter
  --md      Markdown output
  --json    JSON output
  --help    Show this help

Indicators:
  dup_tool   Max duplicate tool calls
  duration   Session duration (minutes)
  rounds     User prompt count
HELP
        return 0
        ;;
      *) prefix="$1"; shift ;;
    esac
  done

  # Allow override for testing
  local projects_dir="${CCS_HEALTH_PROJECTS_DIR:-$HOME/.claude/projects}"

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
      bname=$(basename "$f" .jsonl)
      if [[ "$bname" != "${prefix}"* ]]; then
        continue
      fi
    fi
    files+=("$f")
  done < <(find "$projects_dir" \
    -maxdepth 2 -name "*.jsonl" -type f \
    ! -path "*/subagents/*" \
    -print0 2>/dev/null)

  # Process each session: collect scored JSON
  local results=()
  local f
  for f in "${files[@]}"; do
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

    # Enrich scored JSON with project/topic/last_ts
    scored=$(echo "$scored" | jq \
      --arg proj "$project" \
      --arg topic "$topic" \
      --arg last_ts "$last_ts" \
      '. + {project: $proj, topic: $topic,
            last_ts: $last_ts}')

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

  # ── Output ──
  case "$fmt" in
    json)
      echo "$combined" | jq '.'
      ;;

    md)
      echo "## Session Health Report"
      echo ""
      if [ "$(echo "$combined" \
        | jq 'length')" = "0" ]; then
        echo "(no active sessions)"
        return 0
      fi
      echo "$combined" | jq -r \
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
        ""
      '
      ;;

    terminal|*)
      printf "\033[1mSession Health Report\033[0m\n"
      printf "═══════════════════════\n\n"
      if [ "$(echo "$combined" \
        | jq 'length')" = "0" ]; then
        printf "  \033[90m(no active sessions)\033[0m\n"
        return 0
      fi
      echo "$combined" | jq -r '.[] |
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
          | tostring)
        ] | @tsv
      ' | while IFS=$'\t' read -r \
          overall sid proj topic \
          dup_lv dup_v \
          dur_lv dur_v \
          rnd_lv rnd_v; do

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
        echo
      done

      printf "Legend: "
      printf "\033[32m●\033[0m green  "
      printf "\033[33m◐\033[0m yellow  "
      printf "\033[31m○\033[0m red\n"
      ;;
  esac
}
