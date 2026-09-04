#!/usr/bin/env bash
# ccs-run.sh — Cross-session run token accounting (GH#117)
# Source: ccs-core.sh must be sourced first.

# ── Usage / Help ──
_ccs_run_cost_usage() {
  cat <<'HELP'
Usage: ccs-run-cost [options] <session-id> [<session-id>...]

Cross-session run token accounting (issue #117).

Options:
  --split <ISO8601>     Split usage into stages at ISO8601 timestamp (can be repeated)
  --label <sid>=<name>  Assign a friendly label to a session ID (can be repeated)
  --until <ISO8601>     Only include usage up to and including ISO8601 timestamp
  --no-subagents        Exclude subagents from accounting
  --format md|json      Output format: md (default) or json
  -h, --help            Show this help message
HELP
}

# ── Session resolver ──
_ccs_run_cost_resolve_session() {
  local session_id="${1:?missing session_id}"
  local jsonl=""
  if [ -n "${CCS_PROJECTS_DIR:-}" ]; then
    jsonl=$(find "$CCS_PROJECTS_DIR" -maxdepth 2 \( -name "${session_id}*.jsonl" -o -name "${session_id}*.json" \) ! -path "*/subagents/*" 2>/dev/null | head -1)
  else
    jsonl=$(_ccs_resolve_jsonl "$session_id" "true")
  fi

  if [ -z "$jsonl" ] || [ ! -f "$jsonl" ]; then
    echo "Error: could not resolve session: $session_id" >&2
    return 1
  fi
  echo "$jsonl"
}

# ── Parse single JSONL transcript ──
_ccs_run_cost_parse_file() {
  local file="${1:?missing file}"
  local splits_json="${2:-[]}"
  local until_val="${3:-}"

  jq -s --argjson splits "$splits_json" --arg until "$until_val" '
    def norm_iso:
      if . == null or . == "" then ""
      elif test("\\.[0-9]+Z$") then
        sub("(?<dot>\\.[0-9]{3})[0-9]*Z$"; "\(.dot)Z")
      else
        sub("Z$"; ".000Z")
      end;

    def zero_metrics:
      {
        rows: 0,
        requests: 0,
        input: 0,
        output: 0,
        billable: 0,
        cache_read: 0,
        cache_creation: 0,
        thinking: 0
      };

    def add_metrics($a; $b):
      {
        rows: ($a.rows + $b.rows),
        requests: ($a.requests + $b.requests),
        input: ($a.input + $b.input),
        output: ($a.output + $b.output),
        billable: ($a.billable + $b.billable),
        cache_read: ($a.cache_read + $b.cache_read),
        cache_creation: ($a.cache_creation + $b.cache_creation),
        thinking: ($a.thinking + $b.thinking)
      };

    def init_stages($s_list):
      if ($s_list | length) == 0 then []
      else
        [range(0; ($s_list | length) + 1)] | map(
          . as $idx |
          (if $idx == 0 then null else $s_list[$idx - 1] end) as $from |
          (if $idx == ($s_list | length) then null else $s_list[$idx] end) as $to |
          ({from: $from, to: $to} + zero_metrics)
        )
      end;

    def stage_index($ts; $s_list):
      ($ts | norm_iso) as $nts |
      ([range(0; $s_list | length) | select($nts < ($s_list[.] | norm_iso))] | first) // ($s_list | length);

    # Step 1: select assistant messages that contain token usage
    [.[] | select(.type == "assistant" and (.message.usage != null or .usage != null))] as $raw |

    # Step 2: group by requestId (fallback uuid, fallback unique entry)
    ($raw | group_by(.requestId // .uuid // .)) |

    # Step 3: parse each request group, choosing the record with max apiBlockIndex (fallback last)
    map(
      . as $grp |
      ($grp | sort_by(.apiBlockIndex // 0) | last) as $rep |
      {
        rows: ($grp | length),
        requests: 1,
        timestamp: ($rep.timestamp // ""),
        input: ($rep.message.usage.input_tokens // $rep.usage.input_tokens // 0),
        output: ($rep.message.usage.output_tokens // $rep.usage.output_tokens // 0),
        cache_read: ($rep.message.usage.cache_read_input_tokens // $rep.usage.cache_read_input_tokens // 0),
        cache_creation: ($rep.message.usage.cache_creation_input_tokens // $rep.usage.cache_creation_input_tokens // 0),
        thinking: ($rep.message.usage.output_tokens_details.thinking_tokens // $rep.usage.output_tokens_details.thinking_tokens // 0)
      } |
      .billable = (.input + .output)
    ) |

    # Step 4: filter by --until (inclusive: timestamp <= until)
    # Decision (GH#117): Requests filtered out by --until have their rows deducted as well
    # to maintain consistency between row count and usage totals.
    (if ($until != "" and $until != null) then
      map(select((.timestamp | norm_iso) <= ($until | norm_iso)))
    else
      .
    end) as $reqs |

    # Step 5: compute totals and stages
    ($reqs | reduce .[] as $r (zero_metrics; add_metrics(.; $r))) as $totals |
    (init_stages($splits) as $stgs |
      if ($stgs | length) == 0 then []
      else
        reduce $reqs[] as $r (
          $stgs;
          stage_index($r.timestamp; $splits) as $s_idx |
          .[$s_idx] = (.[$s_idx] as $cur | {from: $cur.from, to: $cur.to} + add_metrics($cur; $r))
        )
      end
    ) as $stages |

    {
      totals: $totals,
      stages: $stages
    }
  ' "$file"
}

# ── Markdown renderer ──
_ccs_run_cost_md() {
  local json_input="${1:?missing json input}"
  jq -r '
    "# Run Cost Report\n",
    "- **Generated at**: \(.generated_at)",
    (if .until != null then "- **Until**: \(.until) (inclusive)" else empty end),
    (if (.splits | length) > 0 then "- **Splits**: \(.splits | join(", "))" else empty end),
    "\n## Summary\n",
    "| Session | Requests | Rows | Input | Output | Billable | Cache Read | Cache Creation | Thinking | Status |",
    "|:---|---:|---:|---:|---:|---:|---:|---:|---:|:---|",
    (
      .sessions[] |
      (if .label != null then "\(.sid) (\(.label))" else .sid end) as $name |
      if .usage_available then
        "| \($name) | \(.with_subagents.requests) | \(.with_subagents.rows) | \(.with_subagents.input) | \(.with_subagents.output) | \(.with_subagents.billable) | \(.with_subagents.cache_read) | \(.with_subagents.cache_creation) | \(.with_subagents.thinking) | OK |"
      else
        (if .provider == "gemini" then
          "| \($name) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | [usage unavailable] / usage 不可得 (Gemini session 無 token usage 欄位) |"
        else
          "| \($name) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | [usage unavailable] / usage 不可得 (解析失敗) |"
        end)
      end
    ),
    "| **Grand Total** | \(.grand_total.requests) | \(.grand_total.rows) | \(.grand_total.input) | \(.grand_total.output) | \(.grand_total.billable) | \(.grand_total.cache_read) | \(.grand_total.cache_creation) | \(.grand_total.thinking) | - |",
    "\n> 本報告僅涵蓋可取得 usage 的 provider。\n",
    (
      .sessions[] | select((.subagents | length) > 0) |
      (if .label != null then "\(.sid) (\(.label))" else .sid end) as $pname |
      "\n### Subagents Breakdown: \($pname)\n\n" +
      "| Agent | Requests | Rows | Input | Output | Billable | Cache Read | Cache Creation | Thinking |\n" +
      "|:---|---:|---:|---:|---:|---:|---:|---:|---:|\n" +
      "| (parent) | \(.totals.requests) | \(.totals.rows) | \(.totals.input) | \(.totals.output) | \(.totals.billable) | \(.totals.cache_read) | \(.totals.cache_creation) | \(.totals.thinking) |\n" +
      (
        .subagents[] |
        "| \(.id) | \(.totals.requests) | \(.totals.rows) | \(.totals.input) | \(.totals.output) | \(.totals.billable) | \(.totals.cache_read) | \(.totals.cache_creation) | \(.totals.thinking) |\n"
      ) +
      "| **With Subagents** | \(.with_subagents.requests) | \(.with_subagents.rows) | \(.with_subagents.input) | \(.with_subagents.output) | \(.with_subagents.billable) | \(.with_subagents.cache_read) | \(.with_subagents.cache_creation) | \(.with_subagents.thinking) |\n"
    ),
    (
      .sessions[] | select((.stages | length) > 0) |
      . as $sess |
      (if $sess.label != null then "\($sess.sid) (\($sess.label))" else $sess.sid end) as $sname |
      "\n### Stages Breakdown: \($sname)\n\n" +
      "| Stage | From | To | Requests | Rows | Input | Output | Billable | Cache Read | Cache Creation | Thinking |\n" +
      "|:---|:---|:---|---:|---:|---:|---:|---:|---:|---:|---:|\n" +
      (
        [range(0; $sess.stages | length)] | map(
          . as $idx |
          ($sess.stages[$idx]) as $stg |
          "| Stage \($idx) | \($stg.from // "-") | \($stg.to // "-") | \($stg.requests) | \($stg.rows) | \($stg.input) | \($stg.output) | \($stg.billable) | \($stg.cache_read) | \($stg.cache_creation) | \($stg.thinking) |\n"
        ) | join("")
      )
    )
  ' <<< "$json_input"
}

# ── Main CLI command ──
ccs-run-cost() {
  local -
  local splits=()
  local labels=()
  local until=""
  local include_subagents=true
  local format="md"
  local session_ids=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        _ccs_run_cost_usage
        return 0
        ;;
      --split)
        [ $# -ge 2 ] || { echo "Error: --split requires an ISO8601 timestamp" >&2; return 1; }
        if [[ ! "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then
          echo "Error: invalid ISO8601 timestamp for --split: '$2' (expected UTC format YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DDTHH:MM:SS.sssZ)" >&2
          return 1
        fi
        splits+=("$2")
        shift 2
        ;;
      --label)
        [ $# -ge 2 ] || { echo "Error: --label requires <sid>=<name>" >&2; return 1; }
        labels+=("$2")
        shift 2
        ;;
      --until)
        [ $# -ge 2 ] || { echo "Error: --until requires an ISO8601 timestamp" >&2; return 1; }
        if [[ ! "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then
          echo "Error: invalid ISO8601 timestamp for --until: '$2' (expected UTC format YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DDTHH:MM:SS.sssZ)" >&2
          return 1
        fi
        until="$2"
        shift 2
        ;;
      --no-subagents)
        include_subagents=false
        shift
        ;;
      --format)
        [ $# -ge 2 ] || { echo "Error: --format requires md or json" >&2; return 1; }
        if [ "$2" != "md" ] && [ "$2" != "json" ]; then
          echo "Error: unknown format '$2'" >&2
          return 1
        fi
        format="$2"
        shift 2
        ;;
      -*)
        echo "Error: unknown option: $1" >&2
        _ccs_run_cost_usage >&2
        return 1
        ;;
      *)
        session_ids+=("$1")
        shift
        ;;
    esac
  done

  if [ ${#session_ids[@]} -eq 0 ]; then
    echo "Error: at least one session-id is required" >&2
    _ccs_run_cost_usage >&2
    return 1
  fi

  # Prepare splits JSON array sorted by normalized ISO8601 timestamp
  local splits_json="[]"
  if [ ${#splits[@]} -gt 0 ]; then
    splits_json=$(printf '%s\n' "${splits[@]}" | jq -R . | jq -s '
      def norm_iso:
        if . == null or . == "" then ""
        elif test("\\.[0-9]+Z$") then
          sub("(?<dot>\\.[0-9]{3})[0-9]*Z$"; "\(.dot)Z")
        else
          sub("Z$"; ".000Z")
        end;
      sort_by(. | norm_iso) | unique_by(. | norm_iso)
    ')
  fi

  local generated_at
  generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local sessions_json_list=()
  local -A seen_sessions=()
  local -A matched_labels=()
  local sid=""
  local l=""

  for sid in "${session_ids[@]}"; do
    local file
    file=$(_ccs_run_cost_resolve_session "$sid") || return 1

    local resolved_uuid
    resolved_uuid=$(basename "$file")
    resolved_uuid="${resolved_uuid%.jsonl}"
    resolved_uuid="${resolved_uuid%.json}"

    if [ -n "${seen_sessions["$resolved_uuid"]:-}" ]; then
      echo "Warning: duplicate session $resolved_uuid ($sid) ignored" >&2
      continue
    fi
    seen_sessions["$resolved_uuid"]=1

    local label="null"
    for l in "${labels[@]}"; do
      if [[ "$l" == "${sid}="* ]]; then
        label="\"${l#"${sid}="}\""
        matched_labels["$l"]=1
        break
      elif [[ "$l" == "${resolved_uuid}="* ]]; then
        label="\"${l#"${resolved_uuid}="}\""
        matched_labels["$l"]=1
        break
      fi
    done

    local provider
    provider=$(_ccs_get_provider "$file")

    if [ "$provider" = "gemini" ]; then
      # Gemini session: no token usage available
      local sess_obj
      sess_obj=$(jq -n \
        --arg sid "$resolved_uuid" \
        --argjson label "$label" \
        --argjson splits "$splits_json" \
        '{
          sid: $sid,
          label: $label,
          provider: "gemini",
          usage_available: false,
          totals: {
            rows: 0,
            requests: 0,
            input: 0,
            output: 0,
            billable: 0,
            cache_read: 0,
            cache_creation: 0,
            thinking: 0
          },
          stages: (if ($splits | length) == 0 then [] else [range(0; ($splits | length) + 1)] | map({from: (if . == 0 then null else $splits[. - 1] end), to: (if . == ($splits | length) then null else $splits[.] end), rows: 0, requests: 0, input: 0, output: 0, billable: 0, cache_read: 0, cache_creation: 0, thinking: 0}) end),
          subagents: [],
          with_subagents: {
            rows: 0,
            requests: 0,
            input: 0,
            output: 0,
            billable: 0,
            cache_read: 0,
            cache_creation: 0,
            thinking: 0
          }
        }')
      sessions_json_list+=("$sess_obj")
    else
      # Claude session
      local parsed_parent
      local parse_failed=false
      if ! parsed_parent=$(_ccs_run_cost_parse_file "$file" "$splits_json" "$until" 2>/dev/null) || [ -z "$parsed_parent" ] || ! echo "$parsed_parent" | jq -e '.totals' >/dev/null 2>&1; then
        parse_failed=true
        echo "Error: failed to parse session $resolved_uuid ($sid): $file" >&2
      fi

      if [ "$parse_failed" = "true" ]; then
        local sess_obj
        sess_obj=$(jq -n \
          --arg sid "$resolved_uuid" \
          --argjson label "$label" \
          --arg provider "$provider" \
          --argjson splits "$splits_json" \
          '{
            sid: $sid,
            label: $label,
            provider: $provider,
            usage_available: false,
            totals: {
              rows: 0,
              requests: 0,
              input: 0,
              output: 0,
              billable: 0,
              cache_read: 0,
              cache_creation: 0,
              thinking: 0
            },
            stages: (if ($splits | length) == 0 then [] else [range(0; ($splits | length) + 1)] | map({from: (if . == 0 then null else $splits[. - 1] end), to: (if . == ($splits | length) then null else $splits[.] end), rows: 0, requests: 0, input: 0, output: 0, billable: 0, cache_read: 0, cache_creation: 0, thinking: 0}) end),
            subagents: [],
            with_subagents: {
              rows: 0,
              requests: 0,
              input: 0,
              output: 0,
              billable: 0,
              cache_read: 0,
              cache_creation: 0,
              thinking: 0
            }
          }')
        sessions_json_list+=("$sess_obj")
      else
        local subagents_json="[]"
        local with_subagents_json
        with_subagents_json=$(echo "$parsed_parent" | jq '.totals')

        if [ "$include_subagents" = "true" ]; then
          local subagents_dir="${file%.*}/subagents"
          if [ -d "$subagents_dir" ]; then
            local sub_items=()
            local sub_files=()
            shopt -s nullglob
            sub_files=("$subagents_dir"/agent-*.jsonl)

            local sfile
            for sfile in "${sub_files[@]}"; do
              local sub_id
              sub_id=$(basename "$sfile" .jsonl)
              local parsed_sub
              if parsed_sub=$(_ccs_run_cost_parse_file "$sfile" "$splits_json" "$until" 2>/dev/null) && [ -n "$parsed_sub" ] && echo "$parsed_sub" | jq -e '.totals' >/dev/null 2>&1; then
                local sub_obj
                sub_obj=$(jq -n --arg id "$sub_id" --argjson ps "$parsed_sub" '{
                  id: $id,
                  totals: $ps.totals,
                  stages: $ps.stages
                }')
                sub_items+=("$sub_obj")
              else
                echo "Warning: failed to parse subagent $sub_id for session $resolved_uuid: $sfile" >&2
              fi
            done

            if [ ${#sub_items[@]} -gt 0 ]; then
              subagents_json=$(printf '%s\n' "${sub_items[@]}" | jq -s .)
              with_subagents_json=$(jq -n --argjson parent "$with_subagents_json" --argjson subs "$subagents_json" '
                def add_m($a; $b): {
                  rows: ($a.rows + $b.rows),
                  requests: ($a.requests + $b.requests),
                  input: ($a.input + $b.input),
                  output: ($a.output + $b.output),
                  billable: ($a.billable + $b.billable),
                  cache_read: ($a.cache_read + $b.cache_read),
                  cache_creation: ($a.cache_creation + $b.cache_creation),
                  thinking: ($a.thinking + $b.thinking)
                };
                reduce $subs[] as $s ($parent; add_m(.; $s.totals))
              ')
            fi
          fi
        fi

        local sess_obj
        sess_obj=$(jq -n \
          --arg sid "$resolved_uuid" \
          --argjson label "$label" \
          --argjson parent "$parsed_parent" \
          --argjson subs "$subagents_json" \
          --argjson with_subs "$with_subagents_json" \
          '{
            sid: $sid,
            label: $label,
            provider: "claude",
            usage_available: true,
            totals: $parent.totals,
            stages: $parent.stages,
            subagents: $subs,
            with_subagents: $with_subs
          }')
        sessions_json_list+=("$sess_obj")
      fi
    fi
  done

  # Warn on any unmatched labels
  for l in "${labels[@]}"; do
    if [ -z "${matched_labels["$l"]:-}" ]; then
      echo "Warning: label '$l' did not match any session" >&2
    fi
  done

  # Combine all sessions into full JSON
  local sessions_array
  sessions_array=$(printf '%s\n' "${sessions_json_list[@]}" | jq -s .)

  local full_json
  full_json=$(jq -n \
    --arg gen_at "$generated_at" \
    --arg until "$until" \
    --argjson splits "$splits_json" \
    --argjson sess "$sessions_array" \
    '
      def zero_metrics:
        {
          rows: 0,
          requests: 0,
          input: 0,
          output: 0,
          billable: 0,
          cache_read: 0,
          cache_creation: 0,
          thinking: 0
        };

      def add_m($a; $b):
        {
          rows: ($a.rows + $b.rows),
          requests: ($a.requests + $b.requests),
          input: ($a.input + $b.input),
          output: ($a.output + $b.output),
          billable: ($a.billable + $b.billable),
          cache_read: ($a.cache_read + $b.cache_read),
          cache_creation: ($a.cache_creation + $b.cache_creation),
          thinking: ($a.thinking + $b.thinking)
        };

      ($sess | map(select(.usage_available == true) | .with_subagents) | reduce .[] as $m (zero_metrics; add_m(.; $m))) as $gt |

      {
        generated_at: $gen_at,
        until: (if $until != "" then $until else null end),
        splits: $splits,
        sessions: $sess,
        grand_total: $gt
      }
    ')

  if [ "$format" = "json" ]; then
    echo "$full_json"
  elif [ "$format" = "md" ]; then
    _ccs_run_cost_md "$full_json"
  else
    echo "Error: unknown format '$format'" >&2
    return 1
  fi
}
