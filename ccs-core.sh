#!/usr/bin/env bash
# ccs-core.sh — Code CLI Sessions (CCS) core helpers and basic commands
# Part of ccs-dashboard. Sourced by ccs-dashboard.sh automatically.
#
# Computed at source time — used to strip $HOME prefix from JSONL directory names.
_CCS_HOME_ENCODED=$(echo "$HOME" | sed 's/\//-/g')
_CCS_DASHBOARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
#
# Helpers:
#   _ccs_session_row        — parse JSONL session → tab-separated row
#   _ccs_topic_from_jsonl   — extract topic from JSONL
#   _ccs_resolve_jsonl      — resolve JSONL file from args
#   _ccs_build_pairs_index  — extract prompt-response index
#   _ccs_get_pair           — extract Nth prompt-response pair
#   _ccs_conversation_md    — filtered conversation pairs as markdown
#   _ccs_recent_files_md    — recent file operations from JSONL
#   _ccs_todos_md           — TodoWrite items from JSONL
#   _ccs_find_project_dir    — find encoded project dir from filesystem path
#   _ccs_resolve_project_path — resolve JSONL dir name → filesystem path
#   _ccs_gemini_chats_dir   — resolve current project's Gemini chats directory
#   _ccs_get_boot_epoch     — system boot time as epoch
#   _ccs_detect_crash       — detect crash-interrupted sessions
#
# Commands:
#   ccs-sessions            — all sessions within N hours
#   ccs-active              — non-archived sessions within N days
#   ccs-cleanup             — kill stopped (suspended) claude processes

# ── Helper: check if a session JSONL is truly archived ──
# A session is archived if:
#   1. last-prompt exists AND no assistant event follows it, OR
#   2. Last user events are /exit commands (Claude Code bug: resume→/exit may not write last-prompt)
# Returns 0 if archived, 1 if not.
_ccs_get_provider() {
  local f="$1"
  if [[ "$f" == *.json ]]; then
    echo "gemini"
  else
    echo "claude"
  fi
}

_ccs_is_archived() {
  local f="$1"
  if [ "$(_ccs_get_provider "$f")" = "gemini" ]; then
    # Gemini: check for injected "archived": true flag
    local is_archived
    is_archived=$(jq -r '.archived // false' "$f" 2>/dev/null)
    if [ "$is_archived" = "true" ]; then
      return 0
    fi
    return 1
  fi
  # Check 1: /exit pattern (handles missing last-prompt after resume→/exit)
  # The /exit sequence writes 3 user events at the very end: caveat, command, stdout.
  # Key signal: last line is a user event containing "Goodbye!" or "See ya!" (exit stdout).
  # No assistant event should follow a real /exit.
  local _last_type _last_content
  _last_type=$(tail -1 "$f" 2>/dev/null | python3 -c "import sys,json; d=json.loads(next(sys.stdin)); print(d.get('type',''))" 2>/dev/null)
  if [ "$_last_type" = "user" ]; then
    _last_content=$(tail -1 "$f" 2>/dev/null | python3 -c "import sys,json; d=json.loads(next(sys.stdin)); c=d.get('message',{}).get('content',''); print(c[:200] if isinstance(c,str) else str(c)[:200])" 2>/dev/null)
    if [[ "$_last_content" == *"local-command-stdout"*"ya!"* ]] || [[ "$_last_content" == *"local-command-stdout"*"Goodbye!"* ]]; then
      return 0
    fi
  fi
  # Check 2: last-prompt with no subsequent resume
  tail -20 "$f" 2>/dev/null | grep -q '"type":"last-prompt"' || return 1
  local has_resume
  has_resume=$(tac "$f" 2>/dev/null | awk '/"type":"last-prompt"/{exit} /"type":"assistant"/{a=1} END{print a+0}')
  [ "${has_resume:-0}" = "0" ]  # return 0 (archived) if no resume
}

# ── Helper: parse one JSONL session file → tab-separated row ──
_ccs_session_row() {
  local f="$1"
  local script_dir
  script_dir="$_CCS_DASHBOARD_DIR"
  python3 "$script_dir/internal/ccs_collect.py" --file "$f" 2>/dev/null
}

# ── Helper: resolve topic from JSONL (Happy title or first user msg) ──
_ccs_topic_from_jsonl() {
  local f="$1"
  local topic=""
  local provider=$(_ccs_get_provider "$f")
  
  if [ "$provider" = "gemini" ]; then
    # Check toolCalls for title change (support both .messages[] and top-level array)
    topic=$(jq -r '
      (if type == "array" then . else .messages // [] end)[]? |
      select(.toolCalls) | .toolCalls[] |
      select(.name == "mcp__happy__change_title") |
      .args.title' "$f" 2>/dev/null | tail -1)
  else
    if grep -q "change_title" "$f" 2>/dev/null; then
      topic=$(grep "change_title" "$f" 2>/dev/null | jq -r '
        .message.content[]? |
        select(.type == "tool_use" and .name == "mcp__happy__change_title") |
        .input.title' 2>/dev/null | tail -1)
    fi
  fi

  if [ -z "$topic" ]; then
    # Find first real user message (skip meta, local-command, system tags, slash commands)
    # Strip XML tags from content to avoid <command-message> etc. leaking into topic
    if [ "$provider" = "gemini" ]; then
      topic=$(jq -r '
        (if type == "array" then . else .messages // [] end)[]?
        | select((.type == "user" or .role == "user") and ((.isMeta // false) == false))
        | (.content // .message.content)
        | if type == "array" then [.[]? | select(.text) | .text] | join(" ") else . end
        | select(test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
        | select(test("^\\s*$") | not)
        | gsub("<[^>]+>"; "") | gsub("^\\s+|\\s+$"; "")
      ' "$f" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c1-120)
    else
      topic=$(jq -r '
        select(.type == "user" and (.message.content | type == "string")
          and ((.isMeta // false) == false)
          and (.message.content | test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
          and (.message.content | test("^\\s*$") | not))
        | .message.content | gsub("<[^>]+>"; "") | gsub("^\\s+|\\s+$"; "")
      ' "$f" 2>/dev/null | head -1 | tr '\n' ' ' | cut -c1-120)
    fi
  fi
  [ -z "$topic" ] && topic="-"
  echo "$topic"
}

# ── Helper: resolve JSONL file from args ──
_ccs_resolve_jsonl() {
  local projects_dir="$HOME/.claude/projects"
  local prefix="${1:-}" search_all="${2:-}"
  if [ -n "$prefix" ]; then
    # Search Claude projects
    local result
    result=$(find "$projects_dir" -maxdepth 2 \( -name "${prefix}*.jsonl" -o -name "${prefix}*.json" \) ! -path "*/subagents/*" 2>/dev/null | head -1)
    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi
    # Fallback: search Gemini chats dirs (more flexibly for UUIDs)
    local gemini_dir="${CCS_GEMINI_DIR:-$HOME/.gemini}"
    find "$gemini_dir/tmp" -maxdepth 3 \( -name "*${prefix}*.json" \) 2>/dev/null | grep "/chats/" | head -1
  else
    local search_dirs=()
    if [ "$search_all" = "true" ]; then
      search_dirs+=("$projects_dir")
      # Add all Gemini project chats dirs
      local gemini_dir="${CCS_GEMINI_DIR:-$HOME/.gemini}"
      if [ -d "$gemini_dir/tmp" ]; then
        local d
        for d in "$gemini_dir/tmp"/*/chats; do
          [ -d "$d" ] && search_dirs+=("$d")
        done
      fi
    else
      local encoded_dir
      encoded_dir=$(_ccs_find_project_dir "$(pwd)") || true
      [ -n "$encoded_dir" ] && search_dirs+=("$projects_dir/$encoded_dir")
      # Also search current project's Gemini chats dir
      local gemini_chats
      gemini_chats=$(_ccs_gemini_chats_dir "$(pwd)") && search_dirs+=("$gemini_chats")
    fi
    [ ${#search_dirs[@]} -eq 0 ] && return 1
    # Find most recently modified session across all search dirs
    local find_args=()
    for d in "${search_dirs[@]}"; do
      [ ${#find_args[@]} -gt 0 ] && find_args+=("-o")
      find_args+=("-path" "$d/*")
    done
    find "${search_dirs[@]}" -maxdepth 2 \( -name "*.jsonl" -o -name "*.json" \) ! -path "*/subagents/*" -printf '%T@\t%p\n' 2>/dev/null \
      | sort -rn | head -1 | cut -f2
  fi
}

# ── Helper: extract prompt-response pairs index from JSONL ──
# Output: tab-separated lines: real_idx \t has_resp \t is_meta \t preview
_ccs_build_pairs_index() {
  local jsonl="$1"
  local provider=$(_ccs_get_provider "$jsonl")
  
  local jq_user_filter
  if [ "$provider" = "gemini" ]; then
    jq_user_filter='select(.value.type == "user" or .value.role == "user")
      | select(.value.isMeta != true)
      | (.value.content // .value.message.content | if type == "array" then [.[]? | select(.text) | .text] | join(" ") else . end) as $txt
      | select($txt | test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
      | select($txt | test("^\\s*$") | not)'
  else
    jq_user_filter='select(.value.type == "user" and (.value.message.content | type == "string"))
      | select(.value.isMeta != true)
      | select(.value.message.content | test("^<local-command|^<command-name|^<system-|^\\s*/exit|^\\s*/quit") | not)
      | select(.value.message.content | test("^\\s*$") | not)'
  fi

  jq -r "
    (if type == \"array\" then . else .messages // [] end)
    | to_entries as \$all
    | [ \$all[] | select(.value.type == \"user\" or .value.role == \"user\") ] as \$all_users
    | [ \$all[] | $jq_user_filter ] as \$filtered_users
    | range(0; (\$filtered_users | length)) as \$i
    | \$filtered_users[\$i] as \$u
    | (\$u.key) as \$start_pos
    | (\$all_users | map(.key == \$u.key) | index(true) + 1) as \$ri
    | (if \$i + 1 < (\$filtered_users | length) then \$filtered_users[\$i+1].key else (\$all | length) end) as \$end_pos
    | (\$all[\$start_pos + 1 : \$end_pos] | map(select(.value.type == \"assistant\" or .value.type == \"gemini\" or .value.type == \"model\" or .value.role == \"assistant\" or .value.role == \"model\")) | length > 0 | tostring) as \$has_resp
    | (\$u.value.content // \$u.value.message.content | if type == \"array\" then [.[]? | select(.text) | .text] | join(\" \") else . end) as \$text
    | (\$u.value.isMeta // false | tostring) as \$is_meta
    | (\$text | .[:120] | gsub(\"\\n\"; \" \")) as \$preview
    | \"\(\$ri)\t\(\$has_resp)\t\(\$is_meta)\t\(\$preview)\"
  " "$jsonl" 2>/dev/null
}

# ── Helper: extract the Nth prompt-response pair ──
# Output: two JSON lines: {role:"user", text:...} and {role:"assistant", text:...}
# Faithfully shows only content between the Nth and (N+1)th user prompt.
# Includes tool_use summaries when text is absent (interrupted turns).
_ccs_get_pair() {
  local jsonl="$1" pair_idx="$2"

  # Extract user prompts, assistant text, AND tool_use summaries
  # so interrupted turns still show what the agent was doing
  if [ "$(_ccs_get_provider "$jsonl")" = "gemini" ]; then
    jq -c '
      (if type == "array" then . else .messages // [] end)[]? |
      if (.type == "user" or .role == "user") then
        {role: "user", text: ((.content // .message.content) | if type == "array" then [.[]? | select(.text) | .text] | join("\n") else (. // "") end)}
      elif (.type == "assistant" or .type == "gemini" or .type == "model" or .role == "assistant" or .role == "model") then
        (.content // .message.content | if type == "array" then
          [.[]? | select(.text) | .text] | join("\n")
        elif type == "string" then .
        else "" end) as $t |
        (((.content // .message.content) | if type == "array" then
          [.[]? | select(.toolCall or .type == "toolCall") | (.toolCall // .) |
            if .name == "read_file" then "📖 Read " + (.args.file_path // "")
            elif .name == "replace" then "✏️ Edit " + (.args.file_path // "")
            elif .name == "write_file" then "📝 Write " + (.args.file_path // "")
            elif .name == "run_shell_command" then "$ " + (.args.command | split("\n") | first | .[:80])
            elif .name == "grep_search" then "🔍 Grep " + (.args.pattern // "")
            elif .name == "glob" then "🔍 Glob " + (.args.pattern // "")
            elif .name == "activate_skill" then "🤖 Skill: " + .args.name
            else "🔧 " + .name end
          ]
        else [] end) +
        (.toolCalls | if type == "array" then
          [.[]? |
            if .name == "read_file" then "📖 Read " + (.args.file_path // "")
            elif .name == "replace" then "✏️ Edit " + (.args.file_path // "")
            elif .name == "write_file" then "📝 Write " + (.args.file_path // "")
            elif .name == "run_shell_command" then "$ " + (.args.command | split("\n") | first | .[:80])
            elif .name == "grep_search" then "🔍 Grep " + (.args.pattern // "")
            elif .name == "glob" then "🔍 Glob " + (.args.pattern // "")
            elif .name == "activate_skill" then "🤖 Skill: " + .args.name
            else "🔧 " + .name end
          ]
        else [] end) | join("\n")) as $tools |
        {role: "assistant", text: $t, tools: $tools}
      else empty end
    ' "$jsonl" 2>/dev/null
  else
    jq -c '
      if .type == "user" and (.message.content | type == "string") then
        {role: "user", text: .message.content}
      elif .type == "assistant" then
        (.message.content | if type == "array" then
          [.[] | select(.type == "text") | .text] | join("\n")
        else . end) as $t |
        (.message.content | if type == "array" then
          [.[] | select(.type == "tool_use") |
            if .name == "Read" then "📖 Read " + .input.file_path
            elif .name == "Edit" then "✏️ Edit " + .input.file_path
            elif .name == "Write" then "📝 Write " + .input.file_path
            elif .name == "Bash" then "$ " + (.input.command | split("\n") | first | .[:80])
            elif .name == "Grep" then "🔍 Grep " + .input.pattern
            elif .name == "Glob" then "🔍 Glob " + .input.pattern
            elif .name == "Agent" then "🤖 Agent: " + (.input.description // "")
            else "🔧 " + .name end
          ] | join("\n")
        else "" end) as $tools |
        (.message.content | if type == "array" then
          [.[] | select(.type == "thinking") | "💭 (thinking...)"] | join("\n")
        else "" end) as $thinking |
        {role: "assistant", text: $t, tools: $tools, thinking: $thinking}
      else empty end
    ' "$jsonl" 2>/dev/null
  fi | jq -sc --argjson idx "$pair_idx" '
      . as $arr |
      [to_entries[] | select(.value.role == "user")] as $users |
      if ($idx < 1 or $idx > ($users | length)) then empty
      else
        $users[$idx - 1].key as $spos |
        (if $idx < ($users | length) then $users[$idx].key else ($arr | length) end) as $epos |
        $arr[$spos],
        # Merge text and tool summaries between this user and next
        ([$arr[$spos + 1 : $epos][] | select(.role == "assistant")] | {
          texts: ([.[].text] | map(select(length > 0)) | join("\n")),
          tools: ([.[].tools] | map(select(length > 0)) | join("\n")),
          thinking: ([.[].thinking] | map(select(length > 0)) | join("\n"))
        }) as $resp |
        (if ($resp.texts | length) > 0 and ($resp.tools | length) > 0 then
          $resp.texts + "\n\n" + $resp.tools
        elif ($resp.texts | length) > 0 then
          $resp.texts
        elif ($resp.tools | length) > 0 then
          "⚡ interrupted — agent was executing:\n" + $resp.tools
        elif ($resp.thinking | length) > 0 then
          "⚡ interrupted — agent was thinking"
        else
          ""
        end) as $combined_text |
        {role: "assistant", text: $combined_text}
      end
    '
}

# ── Helper: extract filtered conversation pairs as markdown ──
# Usage: _ccs_conversation_md <jsonl> <pair_count> <max_user_lines> <max_asst_lines>
_ccs_conversation_md() {
  local jsonl="$1" pair_count="${2:-5}" max_ulines="${3:-5}" max_alines="${4:-8}"
  local provider=$(_ccs_get_provider "$jsonl")
  local asst_label="Claude"
  [ "$provider" = "gemini" ] && asst_label="Gemini"

  # Build filtered pair indices (reuse ccs-resume-prompt logic)
  local -a real_to_raw=()
  local raw_idx=0
  
  local jq_filter
  if [ "$provider" = "gemini" ]; then
    jq_filter='(if type == "array" then . else .messages // [] end)[]? | select(.type == "user" or .role == "user") | [((.isMeta // false) | tostring), ((.content // .message.content) | if type == "array" then [.[]? | select(.text) | .text] | join(" ") else . end | .[:80] | gsub("\n"; " "))] | @tsv'
  else
    jq_filter='select(.type == "user" and (.message.content | type == "string")) | [(.isMeta // false | tostring), (.message.content | .[:80] | gsub("\n"; " "))] | @tsv'
  fi

  while IFS=$'\t' read -r is_meta content; do
    raw_idx=$((raw_idx + 1))
    [ "$is_meta" = "true" ] && continue
    case "$content" in
      '<local-command'*|'<command-name'*|'<system-'*) continue ;;
    esac
    [[ "$content" =~ ^[[:space:]]*/exit ]] && continue
    [[ "$content" =~ ^[[:space:]]*/quit ]] && continue
    [ -z "${content// /}" ] && continue
    real_to_raw+=("$raw_idx")
  done < <(jq -r "$jq_filter" "$jsonl" 2>/dev/null)

  local real_count=${#real_to_raw[@]}
  local start_from=$((real_count - pair_count + 1))
  [ "$start_from" -lt 1 ] && start_from=1

  local ri
  for ((ri = start_from; ri <= real_count; ri++)); do
    local raw_p=${real_to_raw[$((ri - 1))]}
    local pair_json user_text assistant_text
    pair_json=$(_ccs_get_pair "$jsonl" "$raw_p")
    user_text=$(echo "$pair_json" | head -1 | jq -r '.text' 2>/dev/null)
    assistant_text=$(echo "$pair_json" | tail -1 | jq -r '.text' 2>/dev/null)

    local user_preview asst_preview
    user_preview=$(echo "$user_text" | head -"$max_ulines" | cut -c1-200)
    local ul; ul=$(echo "$user_text" | wc -l)
    [ "$ul" -gt "$max_ulines" ] && user_preview="${user_preview}
..."

    asst_preview=$(echo "$assistant_text" | head -"$max_alines" | cut -c1-200)
    local al; al=$(echo "$assistant_text" | wc -l)
    [ "$al" -gt "$max_alines" ] && asst_preview="${asst_preview}
..."

    printf '**[%d/%d] User:**\n%s\n\n' "$ri" "$real_count" "$user_preview"
    printf '**[%d/%d] %s:**\n%s\n\n' "$ri" "$real_count" "$asst_label" "$asst_preview"
  done
}

# ── Helper: extract recent file operations from JSONL ──
_ccs_recent_files_md() {
  local jsonl="$1"
  local provider=$(_ccs_get_provider "$jsonl")
  if [ "$provider" = "gemini" ]; then
    jq -r '
      (if type == "array" then . else .messages // [] end)[]? |
      select(.type == "assistant" or .type == "gemini" or .type == "model" or .role == "assistant" or .role == "model") |
      (.toolCalls // (.content // .message.content | if type == "array" then [.[]? | select(.toolCall or .type == "toolCall") | (.toolCall // .)] else [] end))[]? |
      if .name == "read_file" then "R " + .args.file_path
      elif .name == "replace" then "E " + .args.file_path
      elif .name == "write_file" then "W " + .args.file_path
      elif .name == "run_shell_command" then "$ " + (.args.command | split("\n") | first | .[:80])
      elif .name == "grep_search" then "🔍 Grep " + .args.pattern
      elif .name == "glob" then "🔍 Glob " + .args.pattern
      else empty end
    ' "$jsonl" 2>/dev/null | tail -15 | sort -u
  else
    jq -r '
      select(.type == "assistant") |
      .message.content[]? |
      select(.type == "tool_use") |
      if .name == "Read" then "R " + .input.file_path
      elif .name == "Edit" then "E " + .input.file_path
      elif .name == "Write" then "W " + .input.file_path
      elif .name == "Bash" then "$ " + (.input.command | split("\n") | first | .[:80])
      else empty end
    ' "$jsonl" 2>/dev/null | tail -15 | sort -u
  fi
}

# ── Helper: extract TodoWrite items from JSONL ──
_ccs_todos_md() {
  local jsonl="$1"
  local provider=$(_ccs_get_provider "$jsonl")
  if [ "$provider" = "gemini" ]; then
    jq -r '
      (if type == "array" then . else .messages // [] end)[]? |
      select(.type == "assistant" or .type == "gemini" or .type == "model" or .role == "assistant" or .role == "model") |
      (.toolCalls // (.content // .message.content | if type == "array" then [.[]? | select(.toolCall or .type == "toolCall") | (.toolCall // .)] else [] end))[]? |
      select(.name == "write_todos") |
      .args.todos[]? |
      (if .status == "completed" then "- [x] " elif .status == "in_progress" then "- [~] " else "- [ ] " end) + .content
    ' "$jsonl" 2>/dev/null | tail -20
  else
    jq -r '
      select(.type == "assistant") |
      .message.content[]? |
      select(.type == "tool_use" and .name == "TodoWrite") |
      .input.todos[]? |
      (if .status == "completed" then "- [x] " elif .status == "in_progress" then "- [~] " else "- [ ] " end) + .content
    ' "$jsonl" 2>/dev/null | tail -20
  fi
}

# ── ccs-sessions [hours] — all sessions within N hours (default 24) ──
ccs-sessions() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-sessions [hours]  — all sessions within N hours (default 24)
[personal tool, not official Code CLI]

Colors:
  green        active (< 10 min)
  yellow       recent (< 1 hour)
  blue         idle, open (< 1 day)
  gray         stale, open (> 1 day)
  g̶r̶a̶y̶ ̶s̶t̶r̶i̶k̶e̶  archived (has last-prompt marker)

Topic source: Happy Coder title if set, otherwise first user message.
HELP
    return 0
  fi
  local hours="${1:-24}"
  local mins=$((hours * 60))
  local prev_project=""

  printf "\033[1m%-35s %-5s %-20s %-12s %s\033[0m\n" "PROJECT" "PROV" "SESSION ID" "LAST ACTIVE" "TOPIC"
  printf '%.0s─' {1..100}; echo

  local script_dir
  script_dir="$_CCS_DASHBOARD_DIR"
  
  python3 "$script_dir/internal/ccs_collect.py" --all | awk -F'|' -v max_mins="$mins" '
    $3 <= max_mins { print $0 }
  ' | while IFS='|' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
    if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
      echo
    fi
    prev_project="$proj"
    
    local prov_display="[${prov}]"
    if [ "$prov" = "C" ]; then prov_display="\033[38;5;166m[C]\033[0m"; fi
    if [ "$prov" = "G" ]; then prov_display="\033[38;5;27m[G]\033[0m"; fi
    
    printf "${color}%-35s\033[0m %b %-20s %-12s %s\n" "$display_proj" "$prov_display" "$sid" "$ago_str" "$topic"
  done
}

# ── ccs-active [days] — open (non-archived) sessions within N days (default 7) ──
ccs-active() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'HELP'
ccs-active [days]  — open (non-archived) sessions within N days (default 7)
[personal tool, not official Code CLI]

Colors:
  green        active (< 10 min)
  yellow       recent (< 1 hour)
  blue         idle, open (< 1 day)
  gray         stale, open (> 1 day)
  red 💀       crash-interrupted (detected by ccs-crash logic)

Archived sessions (with last-prompt marker) are excluded.
Topic source: Happy Coder title if set, otherwise first user message.
HELP
    return 0
  fi
  local days="${1:-7}"
  local mins=$((days * 1440))
  local prev_project=""
  local count=0

  printf "\033[1m%-35s %-5s %-20s %-12s %s\033[0m\n" "PROJECT" "PROV" "SESSION ID" "LAST ACTIVE" "TOPIC"
  printf '%.0s─' {1..100}; echo

  local script_dir
  script_dir="$_CCS_DASHBOARD_DIR"
  
  local open_files=()
  local sorted_rows=""
  
  sorted_rows=$(python3 "$script_dir/internal/ccs_collect.py" | awk -F'|' -v max_mins="$mins" '
    $3 <= max_mins && $4 != "archived" { print $0 }
  ')

  while IFS='|' read -r _ _ _ _ _ _ _ _ _ _ filepath; do
    [ -n "$filepath" ] && open_files+=("$filepath")
  done <<< "$sorted_rows"

  # Pass 1.5: detect crash-interrupted sessions (only for Claude for now)
  declare -A crash_map
  local -a _active_projects=()
  local _af
  for _af in "${open_files[@]}"; do
    if [[ "$_af" == *.jsonl ]]; then
      local _dir_name
      _dir_name=$(basename "$(dirname "$_af")")
      _active_projects+=("$(_ccs_resolve_project_path "$_dir_name" 2>/dev/null)")
    else
      _active_projects+=("")
    fi
  done
  _ccs_detect_crash crash_map open_files _active_projects 2>/dev/null

  # Build 8-char sid prefix → crash info lookup
  declare -A crash_short
  local _csid
  for _csid in "${!crash_map[@]}"; do
    crash_short["${_csid:0:8}"]="${crash_map[$_csid]}"
  done

  # Pass 3: display with crash override
  local crash_count=0
  while IFS='|' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
    [ -z "$proj" ] && continue
    if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
      echo
    fi
    prev_project="$proj"

    # Override color for crashed sessions (Claude only)
    if [ "$prov" = "C" ] && [ -n "${crash_short[$sid]+x}" ]; then
      local crash_info="${crash_short[$sid]}"
      local confidence="${crash_info%%:*}"
      if [ "$confidence" = "high" ]; then
        color="\033[31m"  # red
        sid="${sid} 💀"
        crash_count=$((crash_count + 1))
      fi
    fi

    local prov_display="[${prov}]"
    if [ "$prov" = "C" ]; then prov_display="\033[38;5;166m[C]\033[0m"; fi
    if [ "$prov" = "G" ]; then prov_display="\033[38;5;27m[G]\033[0m"; fi

    printf "${color}%-35s\033[0m %b %-20s %-12s %s\n" "$display_proj" "$prov_display" "$sid" "$ago_str" "$topic"
    count=$((count + 1))
  done <<< "$sorted_rows"

  local summary="${#open_files[@]} open sessions (last ${days} days)"
  [ "$crash_count" -gt 0 ] && summary="${summary}, ${crash_count} crashed"
  printf "\n\033[90m%s\033[0m\n" "$summary"
  if [ "$crash_count" -gt 0 ]; then
    printf "\033[90m💀 detail: ccs-crash | cleanup: ccs-crash --clean | batch: ccs-crash --clean-all\033[0m\n"
  fi
}

# ── ccs-cleanup [--dry-run|-n|--force|-f] — kill stopped claude processes ──
ccs-cleanup() {
  local dry_run=false force=false
  for arg in "$@"; do
    case "$arg" in
      --dry-run|-n) dry_run=true ;;
      --force|-f) force=true ;;
      --help|-h)
        cat <<'HELP'
ccs-cleanup [--dry-run|-n] [--force|-f]  — kill stopped (suspended) claude processes
[personal tool, not official Code CLI]

Finds claude processes in Stopped state (Tl/T) and terminates them.
These are typically caused by /exit in waveterm or Ctrl+Z.
Shows PID, RAM, working directory, start/last-active time, and session topic.

  --dry-run, -n   Show what would be killed without doing it
  --force, -f     Skip confirmation prompt
HELP
        return 0 ;;
    esac
  done

  local pids=() total_mb=0
  while IFS= read -r line; do
    local pid rss mb cwd sid topic started last_active
    pid=$(echo "$line" | awk '{print $1}')
    rss=$(echo "$line" | awk '{print $3}')
    mb=$((rss / 1024))
    pids+=("$pid")
    total_mb=$(( total_mb + mb ))

    # Resolve cwd from /proc
    cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "?")
    cwd=$(echo "$cwd" | sed "s|^$HOME/||; s|^$HOME$|~(home)|")

    # Start time from ps (convert to YYYY/MM/DD HH:MM:SS)
    started=$(date -d "$(ps -p "$pid" -o lstart= 2>/dev/null)" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || echo "-")

    # Extract session ID from --resume arg
    sid=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null \
      | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

    # Resolve topic and last-active from JSONL
    topic="-"
    last_active="-"
    if [ -n "$sid" ]; then
      local jsonl
      jsonl=$(find "$HOME/.claude/projects" -maxdepth 2 \( -name "${sid}.jsonl" -o -name "${sid}.json" \) 2>/dev/null | head -1)
      if [ -n "$jsonl" ]; then
        last_active=$(date -d "$(stat -c '%y' "$jsonl")" '+%Y/%m/%d %H:%M:%S' 2>/dev/null || echo "-")
        topic=$(_ccs_topic_from_jsonl "$jsonl")
      fi
    fi

    printf "\033[33m  PID %-8s  %4d MB  %-25s  %s → %s\033[0m\n" "$pid" "$mb" "$cwd" "$started" "$last_active"
    printf "\033[33m  %17s Topic: %s\033[0m\n\n" "" "$topic"
  done < <(ps -eo pid,stat,rss,etime,args | awk '$2 ~ /^T/ && /claude/ && !/awk/')

  if [ ${#pids[@]} -eq 0 ]; then
    echo "No stopped claude processes found."
    return 0
  fi

  printf "Found \033[1m%d\033[0m stopped process(es), total \033[1m%d MB\033[0m RAM\n" "${#pids[@]}" "$total_mb"

  if $dry_run; then
    echo "(dry-run: no processes killed)"
    return 0
  fi

  if ! $force; then
    printf "Kill all %d stopped process(es)? [y/N] " "${#pids[@]}"
    read -r confirm
    case "$confirm" in
      [yY]*) ;;
      *) echo "Aborted."; return 0 ;;
    esac
  fi

  echo "Sending SIGTERM..."
  for pid in "${pids[@]}"; do
    kill -CONT "$pid" 2>/dev/null  # resume first so it can handle SIGTERM
    kill -TERM "$pid" 2>/dev/null
  done
  sleep 1

  # Check survivors, SIGKILL if needed
  local survivors=0
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null
      survivors=$((survivors + 1))
    fi
  done

  if [ "$survivors" -gt 0 ]; then
    printf "  %d process(es) needed SIGKILL\n" "$survivors"
  fi
  printf "\033[32mFreed ~%d MB RAM\033[0m\n" "$total_mb"
}

# ── Helper: get system boot time as epoch ──
# Returns epoch via stdout. Returns 1 if unavailable (e.g., containers).
_ccs_get_boot_epoch() {
  local boot_str
  # Primary: uptime -s
  boot_str=$(uptime -s 2>/dev/null)
  if [ -n "$boot_str" ]; then
    date -d "$boot_str" +%s 2>/dev/null && return 0
  fi
  # Fallback: who -b
  boot_str=$(who -b 2>/dev/null | awk '{print $3, $4}')
  if [ -n "$boot_str" ]; then
    date -d "$boot_str" +%s 2>/dev/null && return 0
  fi
  return 1
}

# ── Helper: detect crash-interrupted sessions ──
# Usage: declare -A crash_map; _ccs_detect_crash crash_map [--reboot-window N] [--idle-window N] [--hung-threshold N] [files_array] [projects_array]
# crash_map[session_id] = "high:reboot" | "high:reboot-idle" | "high:non-reboot" | "high:non-reboot-idle" | "high:hung"
_ccs_detect_crash() {
  local -n _crash_out=$1; shift
  local reboot_window=30 idle_window=1440 hung_threshold=3600

  while [ $# -gt 0 ]; do
    case "$1" in
      --reboot-window) reboot_window="$2"; shift 2 ;;
      --idle-window) idle_window="$2"; shift 2 ;;
      --hung-threshold) hung_threshold="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  # Remaining args: files_array_name projects_array_name
  # Use a flag to track standalone mode and avoid double nameref
  local _standalone=false
  local -a _standalone_files=() _standalone_projects=() _standalone_rows=()
  if [ $# -ge 2 ]; then
    local -n _cd_files=$1 _cd_projects=$2
  else
    _standalone=true
    _ccs_collect_sessions _standalone_files _standalone_projects _standalone_rows
    local -n _cd_files=_standalone_files _cd_projects=_standalone_projects
  fi

  local now=$(date +%s)
  local boot_epoch
  if ! boot_epoch=$(_ccs_get_boot_epoch); then
    boot_epoch=0
    echo "ccs-crash: warning: cannot determine boot time (container?), Path 1 disabled" >&2
  fi

  local reboot_window_start=0 reboot_upper=0
  if [ "$boot_epoch" -gt 0 ]; then
    reboot_window_start=$((boot_epoch - reboot_window * 60))
    reboot_upper=$((boot_epoch + 120))
  fi

  local idle_window_start=$((now - idle_window * 60))

  # Get running session info (once)
  # Method 1: session IDs from --resume or --session args
  local running_sids=""
  running_sids=$(ps -eo args 2>/dev/null | grep -oP '(?<=--resume )[0-9a-f-]{36}|(?<=--session )[0-9a-f-]{36}' | sort -u)
  # Method 2: normalized cwds of all claude or gemini processes
  # Claude Code encodes paths by replacing /._  with -, so we normalize both sides
  # to alphanumeric segments joined by - for comparison.
  local running_cwds_normalized=""
  running_cwds_normalized=$({
    for p in $(pgrep -u "$(id -u)" -f "claude.*--output-format" 2>/dev/null) \
             $(pgrep -u "$(id -u)" -x "claude" 2>/dev/null) \
             $(pgrep -u "$(id -u)" -x "gemini" 2>/dev/null) \
             $(pgrep -u "$(id -u)" -f "bin/gemini|index.mjs gemini|happy-coder" 2>/dev/null); do
      readlink "/proc/$p/cwd" 2>/dev/null
    done
  } | sort -u | sed 's/[\/._]/-/g; s/--*/-/g; s/^-//')

  local count=${#_cd_files[@]}
  local i
  for ((i = 0; i < count; i++)); do
    local f="${_cd_files[$i]}"
    [ -f "$f" ] || continue

    local mtime sid
    if [[ "$f" == *.json ]]; then
       # Claude format: [..., {"timestamp": "..."}]
       # Gemini format: {"lastUpdated": "...", "messages": [...]}
       local last_ts=$(jq -r 'if type == "array" then .[-1].timestamp else .lastUpdated end // empty' "$f" 2>/dev/null)
       if [ -n "$last_ts" ]; then
         mtime=$(date -d "$last_ts" +%s 2>/dev/null || stat -c "%Y" "$f" 2>/dev/null)
       else
         mtime=$(stat -c "%Y" "$f" 2>/dev/null)
       fi
    else
       mtime=$(stat -c "%Y" "$f" 2>/dev/null)
    fi
    [ -n "$mtime" ] || continue
    sid=$(basename "$f" | sed -e 's/\.jsonl$//' -e 's/\.json$//')
    echo "DEBUG: checking $sid, f=$f, mtime=$mtime, age=$((now-mtime))" >&2

    # Path 1: Reboot detection
    # Any pre-boot session without a running process was killed by reboot.
    # Sessions idle before reboot (waiting for user input) have old mtime but
    # their process was still alive until the reboot killed it.
    # --reboot-window controls the "high:reboot" vs "high:reboot-idle" distinction:
    #   within window = was actively writing near boot time
    #   outside window = was idle but process killed by reboot
    if [ "$boot_epoch" -gt 0 ] && [ "$mtime" -lt "$reboot_upper" ]; then
      echo "$running_sids" | grep -qw "$sid" && continue
      if [ "$mtime" -ge "$reboot_window_start" ]; then
        _crash_out["$sid"]="high:reboot"
      else
        _crash_out["$sid"]="high:reboot-idle"
      fi
      continue
    fi

    # Path 2: Non-reboot detection
    # Skip if mtime outside idle window or after boot (already running post-reboot)
    [ "$mtime" -ge "$idle_window_start" ] || continue
    [ "$boot_epoch" -eq 0 ] || [ "$mtime" -ge "$reboot_upper" ] || continue

    # Check if process is still running
    # Method 1: exact session ID match (--resume sessions) — precise
    # Method 2: cwd match (Happy-launched sessions without --resume) — approximate
    local is_running_exact=false is_running_cwd=false
    if echo "$running_sids" | grep -qw "$sid"; then
      is_running_exact=true
    elif [ -n "${_cd_projects[$i]}" ]; then
      # Normalize project dir name to match normalized cwds
      # Both sides: replace /._  with -, collapse multiple -, strip leading -
      local _proj_normalized
      _proj_normalized=$(echo "${_cd_projects[$i]}" | sed 's/[\/._]/-/g; s/--*/-/g; s/^-//')
      [ -n "$_proj_normalized" ] && echo "$running_cwds_normalized" | grep -qE ".*$_proj_normalized$" &&
      is_running_cwd=true
    fi

    # Skip if modified very recently — likely still active (covers fresh non-resume sessions)
    local age=$(( now - mtime ))
    if [ "$age" -lt 120 ]; then
      continue
    fi

    # Hung detection: only for exact process match (--resume).
    # cwd match is approximate — can't tell which session a process belongs to,
    # so skip crash detection entirely for cwd-matched sessions.
    if "$is_running_exact" && [ "$age" -ge "$hung_threshold" ]; then
      _crash_out["$sid"]="high:hung"
      continue
    fi

    # Process running (exact or cwd) — not crashed
    ("$is_running_exact" || "$is_running_cwd") && continue

    # Check for interrupt signals in last assistant message
    # Mid-execution crash: assistant message started but contains no text content
    local has_text=0
    if [[ "$f" == *.json ]]; then
      # Gemini or Claude-exported-JSON: parse whole file
      has_text=$(jq -r '
        (if type == "array" then . else .messages // [] end) |
        [.[] | select(.type == "assistant" or .type == "gemini" or .type == "model")] | last |
        (.message.content // .content) as $c |
        if $c | type == "array" then
          ([$c[] | select(.type == "text" and (.text | length > 0))] | length)
        elif $c | type == "string" then
          ($c | length)
        else 0 end
      ' "$f" 2>/dev/null)
    else
      # Claude JSONL: use tac for speed, but only call jq if assistant message found
      local last_asst
      last_asst=$(tac "$f" 2>/dev/null | grep -m1 -E '"type":"(assistant|gemini|model)"')
      if [ -n "$last_asst" ]; then
        has_text=$(echo "$last_asst" | jq -r '
          (.message.content // .content) as $c |
          if $c | type == "array" then
            ([$c[] | select(.type == "text" and (.text | length > 0))] | length)
          elif $c | type == "string" then
            ($c | length)
          else 0 end
        ' 2>/dev/null)
      fi
    fi

    if [ "${has_text:-0}" = "0" ]; then
      _crash_out["$sid"]="high:non-reboot"
    else
      _crash_out["$sid"]="high:non-reboot-idle"
    fi
  done
}

# ── Helper: find encoded project dir from filesystem path ──
# Given an absolute filesystem path, find the matching directory in ~/.claude/projects/.
# Claude Code's encoding is not a simple sed — underscores, dots, etc. get transformed.
# Strategy: normalize both sides (replace /._  with -, collapse runs, strip leading -)
# and compare. Returns the actual directory name (not full path).
_ccs_find_project_dir() {
  local target="$1"
  local projects_dir="$HOME/.claude/projects"
  [ -z "$target" ] && return 1

  # 1. Try exact match (naive slash-to-dash)
  local exact
  exact=$(printf '%s' "$target" | sed 's|/|-|g')
  [ -d "$projects_dir/$exact" ] && {
    echo "$exact"
    return 0
  }

  # 2. Fuzzy match: normalize both sides (replace /._  with -, collapse, strip leading -)
  local norm_target
  norm_target=$(printf '%s' "$target" \
    | sed 's/[\/._]/-/g; s/--*/-/g; s/^-//')

  local d name norm_name
  for d in "$projects_dir"/*/; do
    [ -d "$d" ] || continue
    name="${d%/}"
    name="${name##*/}"
    norm_name=$(printf '%s' "$name" \
      | sed 's/--*/-/g; s/^-//')
    [ "$norm_name" = "$norm_target" ] && {
      echo "$name"
      return 0
    }
  done
  return 1
}

# ── Helper: resolve Gemini chats directory for a filesystem path ──
# Uses ~/.gemini/projects.json to map path → slug, then returns chats dir.
# Falls back to current project slug if no argument given.
_ccs_gemini_chats_dir() {
  local target="${1:-$(pwd)}"
  local gemini_dir="${CCS_GEMINI_DIR:-$HOME/.gemini}"
  local projects_json="$gemini_dir/projects.json"
  [ -f "$projects_json" ] || return 1

  # Find the slug for this path (exact match or longest prefix match)
  local slug
  slug=$(python3 -c "
import json, sys, os
target = os.path.realpath('$target')
pj = json.load(open('$projects_json'))
best_path, best_slug = '', ''
for path, slug in pj.get('projects', {}).items():
    rp = os.path.realpath(path)
    if target == rp or target.startswith(rp + '/'):
        if len(rp) > len(best_path):
            best_path, best_slug = rp, slug
if best_slug:
    print(best_slug)
" 2>/dev/null)
  [ -z "$slug" ] && return 1

  local chats_dir="$gemini_dir/tmp/$slug/chats"
  [ -d "$chats_dir" ] && echo "$chats_dir" && return 0
  return 1
}

# ── Helper: resolve JSONL directory name → actual filesystem path ──
# JSONL dirs encode paths as: $HOME/tools/ccs-dashboard → -home-user-tools-ccs-dashboard
# Simple sed 's/-/\//g' fails when project names contain hyphens.
# Strategy: greedy match — try longest path first, progressively split remaining hyphens.
_ccs_resolve_project_path() {
  local encoded="$1"
  [ -z "$encoded" ] && return 1

  # Special case: home directory
  if [ "$encoded" = "$_CCS_HOME_ENCODED" ]; then
    echo "$HOME"
    return 0
  fi

  # Convert leading dash to slash
  local raw="/${encoded#-}"

  # Try full path as-is (no hyphens in any segment)
  [ -d "$raw" ] && { echo "$raw"; return 0; }

  # Left-to-right greedy: find the longest existing directory prefix,
  # then recurse on the remainder.
  # Split into segments by '-'
  local IFS='-'
  local -a parts=($raw)
  unset IFS

  # Rebuild path greedily: accumulate segments, try extending with '-' first (keep hyphen),
  # then try '/' (split). Prefer longest directory match.
  local resolved=""
  local i=0
  local len=${#parts[@]}

  while [ $i -lt $len ]; do
    # Try extending current segment with hyphen (greedy: keep as many hyphens as possible)
    local candidate="$resolved"
    local best_j=$i
    local j
    for ((j = len; j > i; j--)); do
      # Build candidate from parts[i..j-1] joined with '-'
      local segment="${parts[$i]}"
      local k
      for ((k = i + 1; k < j; k++)); do
        segment="${segment}-${parts[$k]}"
      done
      local try_path
      if [ -z "$resolved" ]; then
        try_path="$segment"
      else
        try_path="${resolved}/${segment}"
      fi
      # Check if this is a valid directory (or final segment)
      if [ -d "$try_path" ]; then
        resolved="$try_path"
        best_j=$j
        break
      fi
    done

    if [ $best_j -eq $i ]; then
      # No match found, just append with /
      if [ -z "$resolved" ]; then
        resolved="${parts[$i]}"
      else
        resolved="${resolved}/${parts[$i]}"
      fi
      i=$((i + 1))
    else
      i=$best_j
    fi
  done

  echo "$resolved"
}

# _ccs_friendly_project_name — human-readable short name from encoded dir
# Usage: _ccs_friendly_project_name <encoded_dir>
# Returns: friendly name string
#   home dir        → "~(home)"
#   worktree        → "repo-basename/worktree-name"
#   normal project  → basename of resolved path
_ccs_friendly_project_name() {
  local encoded="$1"
  [ -z "$encoded" ] && return 1

  # 1. Home directory
  if [ "$encoded" = "$_CCS_HOME_ENCODED" ]; then
    echo "~(home)"
    return 0
  fi

  # 2. Worktree detection: known prefixes after "--"
  local wt_prefix wt_name repo_encoded repo_path
  for wt_prefix in "--worktrees-" "--claude-worktrees-" "--dev-worktree-"; do
    if [[ "$encoded" == *"$wt_prefix"* ]]; then
      # Split: repo part (before --) and worktree name (after prefix)
      repo_encoded="${encoded%%--*}"
      wt_name="${encoded#*"$wt_prefix"}"

      # Resolve repo part to get its basename
      repo_path=$(_ccs_resolve_project_path "$repo_encoded" 2>/dev/null) || repo_path=""
      local repo_basename
      repo_basename=$(_ccs_friendly_basename "$repo_path" "$repo_encoded")
      echo "${repo_basename}/${wt_name}"
      return 0
    fi
  done

  # 3. Normal project: resolve and take basename
  local proj_path
  proj_path=$(_ccs_resolve_project_path "$encoded" 2>/dev/null) || proj_path=""
  _ccs_friendly_basename "$proj_path" "$encoded"
}

# _ccs_friendly_basename — extract human-readable basename from resolved path + encoded fallback
# When resolved path is a real directory, use its basename directly.
# When not (resolver guessed wrong due to hyphens-vs-underscores), find the actual
# directory in the nearest existing ancestor by matching the trailing encoded segments.
_ccs_friendly_basename() {
  local resolved="$1"
  local encoded="$2"

  # If resolved path exists and is a directory, use its basename directly
  if [ -n "$resolved" ] && [ -d "$resolved" ]; then
    echo "${resolved##*/}"
    return 0
  fi

  # Resolved path doesn't exist — walk up to find nearest existing ancestor,
  # then search it for a directory whose name matches the remaining segments
  # joined with hyphen or underscore (greedy, longest-suffix match).
  if [ -n "$resolved" ]; then
    local parent="$resolved"
    local suffix=""
    while [ -n "$parent" ] && [ "$parent" != "/" ]; do
      local seg="${parent##*/}"
      parent="${parent%/*}"
      suffix="${seg}${suffix:+-${suffix}}"
      if [ -d "$parent" ]; then
        # Try to find a real child directory matching suffix with _ or - variants
        local candidate
        # Try hyphen form
        if [ -d "${parent}/${suffix}" ]; then
          echo "${suffix}"
          return 0
        fi
        # Try underscore form (replace - with _)
        local underscore_suffix="${suffix//-/_}"
        if [ -d "${parent}/${underscore_suffix}" ]; then
          echo "${underscore_suffix}"
          return 0
        fi
        # Scan the parent dir for best match
        for candidate in "$parent"/*/; do
          candidate="${candidate%/}"
          candidate="${candidate##*/}"
          local norm_candidate="${candidate//_/-}"
          if [ "$norm_candidate" = "$suffix" ]; then
            echo "$candidate"
            return 0
          fi
        done
      fi
    done
  fi

  # Final fallback: strip home prefix from encoded, take last hyphen segment
  echo "${encoded##*-}"
}

# ── Helper: redirect command stdout to file (for agent context efficiency) ──
# Usage: _ccs_to_file <path> <cmd> [args...]
# stdout → file, stderr → terminal (visible in Bash tool result)
# Prints one-line confirmation to stdout so agent knows the path.
_CCS_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ccs-dashboard"

_ccs_to_file() {
  local __tofile_dest="$1"; shift
  mkdir -p "$(dirname "$__tofile_dest")"
  "$@" > "$__tofile_dest"
  local __tofile_rc=$?
  if [ $__tofile_rc -eq 0 ]; then
    echo "Output written to: $__tofile_dest"
  else
    echo "Command failed (exit $__tofile_rc). Partial output may be in: $__tofile_dest" >&2
  fi
  return $__tofile_rc
}

# ── Shared helpers (used by multiple modules) ──

_ccs_data_dir() {
  local dir="${XDG_DATA_HOME:-$HOME/.local/share}/ccs-dashboard"
  mkdir -p "$dir"
  echo "$dir"
}

# Usage: _ccs_collect_sessions [-a|--all] out_files out_projects out_rows
# Three nameref output arrays.
# Output format (TAB-separated row):
#   f1=prov  f2=project  f3=ago_min  f4=status  f5=color  f6=display_line  f7=badge
# _out_projects stores the encoded dir name (for _ccs_resolve_project_path).
_ccs_collect_sessions() {
  local show_all=""
  if [ "${1:-}" = "-a" ] || [ "${1:-}" = "--all" ]; then
    show_all="--all"; shift
  fi

  local -n _out_files=$1 _out_projects=$2 _out_rows=$3

  local script_dir
  script_dir="$_CCS_DASHBOARD_DIR"

  local cutoff
  cutoff=$(date -d "7 days ago" +%s 2>/dev/null || date -v-7d +%s 2>/dev/null)

  while IFS='|' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
    [ -z "$proj" ] && continue

    if [ -z "$show_all" ]; then
       local mod
       mod=$(stat -c "%Y" "$filepath" 2>/dev/null || echo 0)
       [ "$mod" -lt "$cutoff" ] 2>/dev/null && continue
    fi

    # Recover encoded dir name for _ccs_resolve_project_path
    local encoded_dir
    if [ "$prov" = "C" ]; then
      encoded_dir=$(basename "$(dirname "$filepath")")
    else
      encoded_dir="$proj"
    fi

    # Build TAB-separated row (backward-compatible + prov prefix)
    local display
    display=$(printf '%-35s %-20s %-12s %s' "$proj" "$sid" "$ago_str" "$topic")

    _out_files+=("$filepath")
    _out_projects+=("$encoded_dir")
    _out_rows+=("$(printf '%s\t%s\t%d\t%s\t%s\t%s\t%s' "$prov" "$proj" "$ago" "$status" "$color" "$display" "$badge")")
  done < <(python3 "$script_dir/internal/ccs_collect.py" $show_all)
}

# Helper: format "N ago" from minutes
_ccs_ago_str() {
  local ago=$1
  if [ "$ago" -lt 60 ]; then
    printf '%dm ago' "$ago"
  elif [ "$ago" -lt 1440 ]; then
    printf '%dh ago' "$((ago / 60))"
  else
    printf '%dd ago' "$((ago / 1440))"
  fi
}
