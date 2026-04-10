Issue: #40
PR: #41

# Multi-Provider Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Python-based session collection layer for Claude and Gemini CLI sessions and integrate it into `ccs-status` and `ccs-active` commands with a unified UI.

**Architecture:** We are creating a Python script `internal/ccs_collect.py` that reads both `~/.claude/projects/*.jsonl` and `~/.gemini/tmp/*/chats/*.json` to extract sessions, compute standard metadata, and output Tab-Separated Values (TSV). Bash commands in `ccs-core.sh` and `ccs-dashboard.sh` will consume this TSV output. `ccs-status` will be updated to display a `PROV` column.

**Tech Stack:** Python 3 (stdlib only, `json`, `os`, `sys`, `time`), Bash

---

### Task 1: Create Python Session Collector Base

**Files:**
- Create: `internal/ccs_collect.py`

- [ ] **Step 1: Write initial Python script**

Create `internal/ccs_collect.py` with parsing logic for Claude files and CLI argument handling (`--all`, `--file <path>`).

```python
#!/usr/bin/env python3
import json
import os
import sys
import time

def get_status_and_color(ago_mins, is_archived):
    if is_archived:
        return "archived", "\033[90m\033[9m" # gray + strikethrough
    elif ago_mins < 10:
        return "active", "\033[32m" # green
    elif ago_mins < 60:
        return "recent", "\033[33m" # yellow
    elif ago_mins < 1440:
        return "idle", "\033[34m" # blue
    else:
        return "stale", "\033[90m" # gray

def get_ago_str(ago_mins):
    if ago_mins < 60:
        return f"{ago_mins:3d}m ago"
    elif ago_mins < 1440:
        return f"{ago_mins // 60:3d}h ago"
    else:
        return f"{ago_mins // 1440:3d}d ago"

def check_claude_archived(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            if not lines:
                return False
            try:
                last_line = json.loads(lines[-1])
                if last_line.get('type') == 'user':
                    content = last_line.get('message', {}).get('content', '')
                    if isinstance(content, str) and ('local-command-stdout' in content) and ('ya!' in content or 'Goodbye!' in content):
                        return True
            except json.JSONDecodeError:
                pass

            has_last_prompt = False
            has_assistant_after = False
            for line in reversed(lines[-20:]):
                if '"type":"last-prompt"' in line:
                    has_last_prompt = True
                    break
                if '"type":"assistant"' in line:
                    has_assistant_after = True
            if has_last_prompt and not has_assistant_after:
                return True
    except Exception:
        pass
    return False

def get_claude_topic(filepath):
    topic = "-"
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            for line in reversed(lines):
                if 'change_title' in line:
                    try:
                        data = json.loads(line)
                        if data.get('type') == 'assistant':
                            for content in data.get('message', {}).get('content', []):
                                if content.get('type') == 'tool_use' and content.get('name') == 'mcp__happy__change_title':
                                    topic = content.get('input', {}).get('title', '')
                                    if topic:
                                        return topic.replace('\n', ' ').replace('\t', ' ')
                    except json.JSONDecodeError:
                        continue
            for line in lines:
                try:
                    data = json.loads(line)
                    if data.get('type') == 'user' and not data.get('isMeta', False):
                        content = data.get('message', {}).get('content', '')
                        if isinstance(content, str):
                            if not content.startswith('<local-command') and not content.startswith('<command-name') and not content.startswith('<system-') and not content.strip().startswith('/exit') and not content.strip().startswith('/quit') and content.strip():
                                import re
                                clean_content = re.sub(r'<[^>]+>', '', content).strip()
                                if clean_content:
                                    return clean_content[:120].replace('\n', ' ').replace('\t', ' ')
                except json.JSONDecodeError:
                    continue
    except Exception:
        pass
    return topic

def process_claude_file(filepath):
    ccs_home_encoded = os.path.expanduser('~').replace('/', '-')
    dir_name = os.path.basename(os.path.dirname(filepath))
    project = dir_name
    if project.startswith(ccs_home_encoded + '-'):
        project = project[len(ccs_home_encoded)+1:].replace('-', '/')
    elif project == ccs_home_encoded:
        project = "~(home)"
    else:
        project = project.replace('-', '/')
    
    if not project:
        project = "~(home)"
        
    sid = os.path.basename(filepath)[:-6][:8]
    try:
        mtime = os.path.getmtime(filepath)
    except OSError:
        return None
        
    now = time.time()
    ago_mins = int((now - mtime) / 60)
    
    is_archived = check_claude_archived(filepath)
    status, color = get_status_and_color(ago_mins, is_archived)
    ago_str = get_ago_str(ago_mins)
    topic = get_claude_topic(filepath)
    
    return {
        'provider': 'C', 'filepath': filepath, 'project': project,
        'ago_mins': ago_mins, 'status': status, 'color': color,
        'display_project': project, 'sid': sid, 'ago_str': ago_str,
        'topic': topic, 'badge': ''
    }

def collect_claude_sessions(show_all):
    sessions = []
    projects_dir = os.path.expanduser('~/.claude/projects')
    if not os.path.isdir(projects_dir):
        return sessions
    for root, dirs, files in os.walk(projects_dir):
        depth = root[len(projects_dir):].count(os.sep)
        if depth > 1: continue
        if not show_all and 'subagents' in root: continue
            
        for file in files:
            if not file.endswith('.jsonl'): continue
            filepath = os.path.join(root, file)
            s = process_claude_file(filepath)
            if s: sessions.append(s)
    return sessions

def main():
    show_all = '--all' in sys.argv or '-a' in sys.argv
    file_arg = None
    if '--file' in sys.argv:
        idx = sys.argv.index('--file')
        if idx + 1 < len(sys.argv):
            file_arg = sys.argv[idx + 1]

    sessions = []
    if file_arg:
        if file_arg.endswith('.jsonl'):
            s = process_claude_file(file_arg)
            if s: sessions.append(s)
    else:
        sessions.extend(collect_claude_sessions(show_all))
    
    sessions.sort(key=lambda x: (x['project'], x['ago_mins']))
    
    for s in sessions:
        # 11 columns TSV format:
        # prov \t proj \t ago \t status \t color \t display_proj \t sid \t ago_str \t topic \t badge \t filepath
        print(f"{s['provider']}\t{s['project']}\t{s['ago_mins']}\t{s['status']}\t{s['color']}\t{s['display_project']}\t{s['sid']}\t{s['ago_str']}\t{s['topic']}\t{s['badge']}\t{s['filepath']}")

if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Ensure executable permissions**

```bash
chmod +x internal/ccs_collect.py
```

### Task 2: Implement Gemini Session Parsing

**Files:**
- Modify: `internal/ccs_collect.py`

- [ ] **Step 1: Add `process_gemini_file` and `collect_gemini_sessions`**

```python
def get_gemini_topic(data):
    topic = "-"
    messages = data.get('messages', [])
    for msg in reversed(messages):
        if msg.get('role') == 'model':
            for content in msg.get('content', []):
                if content.get('type') == 'toolCall' and content.get('name') == 'mcp__happy__change_title':
                    args = content.get('args', {})
                    topic_str = args.get('title', '')
                    if topic_str:
                        return topic_str.replace('\n', ' ').replace('\t', ' ')

    for msg in messages:
        if msg.get('role') == 'user':
            for content in msg.get('content', []):
                if content.get('type') == 'text':
                    text = content.get('text', '').strip()
                    if text and not text.startswith('/'):
                        import re
                        clean_text = re.sub(r'<[^>]+>', '', text).strip()
                        if clean_text:
                            return clean_text[:120].replace('\n', ' ').replace('\t', ' ')
    return topic

def process_gemini_file(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        return None
        
    filename = os.path.basename(filepath)
    sid = data.get('sessionId', filename.replace('.json', ''))
    display_sid = sid.split('-')[-1][:8] if '-' in sid else sid[:8]
    
    last_updated = data.get('lastUpdated', 0)
    now = time.time() * 1000 
    
    if last_updated == 0:
        try:
            last_updated = os.path.getmtime(filepath) * 1000
        except OSError:
            return None
    
    ago_mins = int((now - last_updated) / 60000)
    if ago_mins < 0: ago_mins = 0
    
    is_archived = False # Gemini lacks archived concept right now
    status, color = get_status_and_color(ago_mins, is_archived)
    ago_str = get_ago_str(ago_mins)
    topic = get_gemini_topic(data)
    
    # Project is the dir name above 'chats'
    project = os.path.basename(os.path.dirname(os.path.dirname(filepath)))
    
    return {
        'provider': 'G', 'filepath': filepath, 'project': project,
        'ago_mins': ago_mins, 'status': status, 'color': color,
        'display_project': project, 'sid': display_sid, 'ago_str': ago_str,
        'topic': topic, 'badge': ''
    }

def collect_gemini_sessions(show_all):
    sessions = []
    gemini_dir = os.path.expanduser('~/.gemini')
    for base_dir in ['tmp', 'history']:
        target_dir = os.path.join(gemini_dir, base_dir)
        if not os.path.isdir(target_dir): continue
        for project_dir in os.listdir(target_dir):
            chats_dir = os.path.join(target_dir, project_dir, 'chats')
            if not os.path.isdir(chats_dir): continue
            for file in os.listdir(chats_dir):
                if not file.endswith('.json'): continue
                filepath = os.path.join(chats_dir, file)
                s = process_gemini_file(filepath)
                if s: sessions.append(s)
    return sessions
```

- [ ] **Step 2: Update `main` to hook up Gemini**

```python
    if file_arg:
        if file_arg.endswith('.jsonl'):
            s = process_claude_file(file_arg)
        elif file_arg.endswith('.json'):
            s = process_gemini_file(file_arg)
        if s: sessions.append(s)
    else:
        sessions.extend(collect_claude_sessions(show_all))
        sessions.extend(collect_gemini_sessions(show_all))
```

### Task 3: Migrate Core Bash Helpers

**Files:**
- Modify: `ccs-core.sh`

- [ ] **Step 1: Rewrite `_ccs_session_row`**

Replace `_ccs_session_row` body in `ccs-core.sh` with a call to the new script.

```bash
_ccs_session_row() {
  local f="$1"
  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  python3 "$script_dir/internal/ccs_collect.py" --file "$f" 2>/dev/null
}
```

- [ ] **Step 2: Rewrite `_ccs_collect_sessions`**

```bash
_ccs_collect_sessions() {
  local show_all=""
  if [ "${1:-}" = "-a" ] || [ "${1:-}" = "--all" ]; then
    show_all="--all"; shift
  fi

  local -n _out_files=$1 _out_projects=$2 _out_rows=$3
  
  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  
  # Note: The cutoff filtering is still handled in Bash here for backwards compatibility
  local cutoff
  cutoff=$(date -d "7 days ago" +%s 2>/dev/null || date -v-7d +%s 2>/dev/null)
  
  while IFS=$'\t' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
    [ -z "$proj" ] && continue
    
    # Re-implement the 7-day cutoff for default collection
    if [ -z "$show_all" ]; then
       local mod
       mod=$(stat -c "%Y" "$filepath" 2>/dev/null || echo 0)
       [ "$mod" -lt "$cutoff" ] 2>/dev/null && continue
    fi
    
    _out_files+=("$filepath")
    _out_projects+=("$proj")
    _out_rows+=("$prov	$proj	$ago	$status	$color	$display_proj	$sid	$ago_str	$topic	$badge	$filepath")
  done < <(python3 "$script_dir/internal/ccs_collect.py" $show_all)
}
```

### Task 4: Update Active / Sessions Commands

**Files:**
- Modify: `ccs-core.sh`

- [ ] **Step 1: Update `ccs-sessions`**

```bash
# Locate ccs-sessions()
  printf "\033[1m%-35s %-5s %-20s %-12s %s\033[0m\n" "PROJECT" "PROV" "SESSION ID" "LAST ACTIVE" "TOPIC"
  printf '%.0s─' {1..100}; echo

  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  
  python3 "$script_dir/internal/ccs_collect.py" --all | awk -F'\t' -v max_mins="$mins" '
    $3 <= max_mins { print $0 }
  ' | while IFS=$'\t' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
    if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
      echo
    fi
    prev_project="$proj"
    
    local prov_display="[${prov}]"
    if [ "$prov" = "C" ]; then prov_display="\033[38;5;166m[C]\033[0m"; fi
    if [ "$prov" = "G" ]; then prov_display="\033[38;5;27m[G]\033[0m"; fi
    
    printf "${color}%-35s\033[0m %b %-20s %-12s %s\n" "$display_proj" "$prov_display" "$sid" "$ago_str" "$topic"
  done
```

- [ ] **Step 2: Update `ccs-active`**

```bash
# Locate ccs-active()
  printf "\033[1m%-35s %-5s %-20s %-12s %s\033[0m\n" "PROJECT" "PROV" "SESSION ID" "LAST ACTIVE" "TOPIC"
  printf '%.0s─' {1..100}; echo

  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")"
  
  local open_files=()
  local sorted_rows=""
  
  sorted_rows=$(python3 "$script_dir/internal/ccs_collect.py" | awk -F'\t' -v max_mins="$mins" '
    $3 <= max_mins && $4 != "archived" { print $0 }
  ')

  while IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ filepath; do
    [ -n "$filepath" ] && open_files+=("$filepath")
  done <<< "$sorted_rows"
  
  # ... leave crash detection block untouched ...

  while IFS=$'\t' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
    [ -z "$proj" ] && continue
    if [ -n "$prev_project" ] && [ "$proj" != "$prev_project" ]; then
      echo
    fi
    prev_project="$proj"

    if [ "$prov" = "C" ] && [ -n "${crash_short[$sid]+x}" ]; then
      local crash_info="${crash_short[$sid]}"
      local confidence="${crash_info%%:*}"
      if [ "$confidence" = "high" ]; then
        color="\033[31m"
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
```

### Task 5: Update ccs-status Markdown Output and Clean Up

**Files:**
- Modify: `ccs-dashboard.sh`

- [ ] **Step 1: Update `ccs-status` loop**

In `ccs-dashboard.sh` (where `ccs-status` consumes `_block_rows`):

```bash
          local idx=1
          while IFS=$'\t' read -r prov proj ago status color display_proj sid ago_str topic badge filepath; do
            [ -z "$proj" ] && continue
            
            # Apply crash override (only for Claude for now)
            if [ "$prov" = "C" ] && [ -n "${crash_short[$sid]+x}" ] && [ "$confidence" = "high" ]; then
               color="\033[31m"
               badge="💀"
            fi
            
            if [ "$opt_md" = true ]; then
              local badge_md=""; [ -n "$badge" ] && badge_md=" ${badge}"
              local prov_md=""
              if [ "$prov" = "C" ]; then prov_md="[Claude] "; fi
              if [ "$prov" = "G" ]; then prov_md="[Gemini] "; fi
              
              if [ "$opt_table" = true ]; then
                echo "| $icon | **$idx** | $prov_md**$topic**$badge_md | \`$sid\` | $ago_str |"
              else
                echo "$icon **$idx.** $prov_md**$topic**$badge_md \`$sid\` $ago_str"
              fi
            else
              local prov_display="[${prov}]"
              if [ "$prov" = "C" ]; then prov_display="\033[38;5;166m[C]\033[0m"; fi
              if [ "$prov" = "G" ]; then prov_display="\033[38;5;27m[G]\033[0m"; fi
              printf "${color}%-35s\033[0m %b %-20s %-12s %s%s\n" "$display_proj" "$prov_display" "$sid" "$ago_str" "$topic" " $badge"
            fi
            idx=$((idx + 1))
          done <<< "$_block_rows"
```

- [ ] **Step 2: Update tests to pass**

Run: `tests/run-all.sh` and fix any string formatting breakages (e.g. `test-core.sh` or `test-status.sh` might expect old output format). Note: tests that mock `_ccs_session_row` using `printf` will need their mock updated to 11 columns separated by `\t`.

- [ ] **Step 3: Commit**

```bash
git add internal/ccs_collect.py ccs-core.sh ccs-dashboard.sh
git commit -m "feat: integrate python session collector to ccs-status"
```
