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
                                        return topic.replace('\n', ' ').replace('\t', ' ').replace('|', ':')
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
                                    return clean_content[:120].replace('\n', ' ').replace('\t', ' ').replace('|', ':')
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
    projects_dir = os.environ.get('CCS_PROJECTS_DIR', os.path.expanduser('~/.claude/projects'))
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
                        return topic_str.replace('\n', ' ').replace('\t', ' ').replace('|', ':')

    for msg in messages:
        if msg.get('role') == 'user':
            for content in msg.get('content', []):
                if content.get('type') == 'text':
                    text = content.get('text', '').strip()
                    if text and not text.startswith('/'):
                        import re
                        clean_text = re.sub(r'<[^>]+>', '', text).strip()
                        if clean_text:
                            return clean_text[:120].replace('\n', ' ').replace('\t', ' ').replace('|', ':')
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
    if last_updated is None: last_updated = 0
    
    now = time.time() * 1000 
    
    if last_updated == 0:
        try:
            last_updated = os.path.getmtime(filepath) * 1000
        except OSError:
            return None
    
    try:
        last_updated = float(last_updated)
    except (ValueError, TypeError):
        last_updated = 0
        
    ago_mins = int((now - last_updated) / 60000)
    if ago_mins < 0: ago_mins = 0
    
    is_archived = False 
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
    gemini_dir = os.environ.get('CCS_GEMINI_DIR', os.path.expanduser('~/.gemini'))
    if not os.path.isdir(gemini_dir):
        return sessions
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

def main():
    show_all = '--all' in sys.argv or '-a' in sys.argv
    file_arg = None
    if '--file' in sys.argv:
        idx = sys.argv.index('--file')
        if idx + 1 < len(sys.argv):
            file_arg = sys.argv[idx + 1]

    sessions = []
    if file_arg:
        s = None
        if file_arg.endswith('.jsonl'):
            s = process_claude_file(file_arg)
        elif file_arg.endswith('.json'):
            s = process_gemini_file(file_arg)
        if s: sessions.append(s)
    else:
        sessions.extend(collect_claude_sessions(show_all))
        sessions.extend(collect_gemini_sessions(show_all))
    
    sessions.sort(key=lambda x: (x['project'], x['ago_mins']))
    
    for s in sessions:
        # 11 columns pipe-separated format:
        # prov | proj | ago | status | color | display_proj | sid | ago_str | topic | badge | filepath
        line = f"{s['provider']}|{s['project']}|{s['ago_mins']}|{s['status']}|{s['color']}|{s['display_project']}|{s['sid']}|{s['ago_str']}|{s['topic']}|{s['badge']}|{s['filepath']}"
        print(line)

if __name__ == '__main__':
    main()
