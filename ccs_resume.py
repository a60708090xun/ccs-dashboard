#!/usr/bin/env python3
import json
import sys
import argparse
import re

def truncate_text(text, limit=150):
    if not text:
        return ""
    if len(text) <= limit:
        return text
    truncated_part = len(text) - limit
    return text[:limit] + f"... [truncated {truncated_part} chars]"

def format_args(args, limit=150):
    if not isinstance(args, dict):
        return str(args)
    items = []
    for k, v in args.items():
        val_str = str(v).replace('\n', ' ')
        items.append(f"{k}: {truncate_text(val_str, limit)}")
    return ", ".join(items)

def parse_session(file_obj, provider, pairs_count=3, limit=150):
    events = []
    if provider == "gemini":
        try:
            data = json.load(file_obj)
            messages = data if isinstance(data, list) else data.get('messages', [])
            for msg in messages:
                role = msg.get('role', msg.get('type', ''))
                # Map Gemini structure to normalized events
                if role == 'user':
                    content = msg.get('content', '')
                    if isinstance(content, list):
                        text_parts = []
                        for c in content:
                            if isinstance(c, dict):
                                text_parts.append(c.get('text', ''))
                            elif isinstance(c, str):
                                text_parts.append(c)
                        text = " ".join([t for t in text_parts if t]).strip()
                    else:
                        text = str(content)
                    
                    # Clean HTML tags and ignore meta commands starting with '/'
                    clean_text = re.sub(r'<[^>]+>', '', text).strip()
                    if clean_text and not clean_text.startswith('/'):
                        events.append({'role': 'user', 'text': clean_text})
                elif role in ['model', 'assistant', 'gemini']:
                    # Text content
                    text_parts = []
                    content = msg.get('content', [])
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict):
                                if c.get('type') == 'text' or 'text' in c:
                                    text_parts.append(c.get('text', ''))
                            elif isinstance(c, str):
                                text_parts.append(c)
                    elif isinstance(content, str):
                        text_parts.append(content)
                    text = " ".join([t for t in text_parts if t]).strip()
                    if text:
                        events.append({'role': 'assistant', 'text': text})
                    # Tool Calls
                    for tc in msg.get('toolCalls', []):
                        name = tc.get('name', '')
                        if name == 'mcp__happy__change_title':
                            continue
                        args = tc.get('args', {})
                        events.append({'role': 'tool_use', 'name': name, 'args': args})
                elif role == 'tool' or msg.get('type') == 'tool':
                    # Tool response
                    for tc in msg.get('toolCalls', []):
                        # Matching result
                        res = tc.get('result', '')
                        events.append({'role': 'tool_result', 'output': str(res)})
        except Exception:
            pass
    else:  # Claude (JSONL)
        for line in file_obj:
            if not line.strip():
                continue
            try:
                data = json.loads(line)
                if data.get('isMeta') is True:
                    # Capture tool results
                    content = data.get('message', {}).get('content', '')
                    if isinstance(content, str):
                        # Clean local-command tags
                        clean_content = re.sub(r'<[^>]+>', '', content).strip()
                        events.append({'role': 'tool_result', 'output': clean_content})
                    continue
                
                role = data.get('type')
                if role == 'user':
                    content = data.get('message', {}).get('content', '')
                    if isinstance(content, str):
                        clean_content = re.sub(r'<[^>]+>', '', content).strip()
                        if clean_content and not clean_content.startswith('/'):
                            events.append({'role': 'user', 'text': clean_content})
                elif role == 'assistant':
                    content_list = data.get('message', {}).get('content', [])
                    if isinstance(content_list, list):
                        for c in content_list:
                            if c.get('type') == 'text':
                                events.append({'role': 'assistant', 'text': c.get('text', '')})
                            elif c.get('type') == 'tool_use':
                                name = c.get('name', '')
                                if name == 'mcp__happy__change_title':
                                    continue
                                events.append({'role': 'tool_use', 'name': name, 'args': c.get('input', {})})
                    elif isinstance(content_list, str):
                        events.append({'role': 'assistant', 'text': content_list})
            except Exception:
                continue

    # Assemble normalized events into User-Assistant conversation turns/pairs
    # Aggregate sequential events under the same role, especially tool uses
    turns = []
    current_user = []
    current_asst = []
    
    for ev in events:
        if ev['role'] in ['user', 'tool_result']:
            if current_asst:
                turns.append({'user': "\n\n".join(current_user), 'assistant': "\n\n".join(current_asst)})
                current_user = []
                current_asst = []
            if ev['role'] == 'user':
                current_user.append(ev['text'])
            else:
                current_user.append(f"📥 [content/output: {truncate_text(ev['output'], limit)}]")
        elif ev['role'] in ['assistant', 'tool_use']:
            if ev['role'] == 'assistant':
                current_asst.append(ev['text'])
            else:
                current_asst.append(f"🛠️ {ev['name']} [{format_args(ev['args'], limit)}]")
                
    if current_user or current_asst:
        turns.append({'user': "\n\n".join(current_user), 'assistant': "\n\n".join(current_asst)})

    # Take the last N pairs
    return turns[-pairs_count:] if pairs_count > 0 else turns

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--file', required=True)
    parser.add_argument('--provider', default='claude')
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--limit', type=int, default=150)
    args = parser.parse_args()

    try:
        with open(args.file, 'r', encoding='utf-8') as f:
            turns = parse_session(f, args.provider, args.pairs, args.limit)
            
        for i, turn in enumerate(turns):
            print(f"### [{i+1}/{len(turns)}] User\n{turn['user']}\n")
            print(f"### [{i+1}/{len(turns)}] Assistant\n{turn['assistant']}\n")
    except Exception as e:
        print(f"Error parsing session: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
