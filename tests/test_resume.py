# Create tests/test_resume.py
import unittest
import json
import io
import sys
import os

# Ensure the parent directory is in sys.path so we can import ccs_resume
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from ccs_resume import parse_session, truncate_text

class TestResumeParser(unittest.TestCase):
    def test_truncate_text(self):
        self.assertEqual(truncate_text("short", 10), "short")
        long_str = "A" * 200
        truncated = truncate_text(long_str, 150)
        self.assertTrue(truncated.endswith("... [truncated 50 chars]"))
        self.assertEqual(len(truncated.split("... [truncated")[0]), 150)

    def test_parse_claude_jsonl(self):
        # Sample Claude Session Log
        jsonl_data = (
            '{"type":"user","message":{"content":"Hello"}}\n'
            '{"type":"assistant","message":{"content":[{"type":"text","text":"Hi! Use tool."},{"type":"tool_use","name":"Read","input":{"file_path":"test.py"}}]}}\n'
            '{"type":"user","isMeta":true,"message":{"content":"<local-command-stdout>print(\'hello\')</local-command-stdout>"}}\n'
            '{"type":"assistant","message":{"content":"Done!"}}\n'
        )
        f = io.StringIO(jsonl_data)
        pairs = parse_session(f, "claude", pairs_count=2, limit=150)
        self.assertEqual(len(pairs), 2)
        # Verify first pair (User: Hello, Assistant text and compressed tool)
        self.assertEqual(pairs[0]['user'], "Hello")
        self.assertIn("🛠️ Read [file_path: test.py]", pairs[0]['assistant'])
        # Verify second pair (Tool Result output mapped, Assistant: Done!)
        self.assertEqual(pairs[1]['user'], "📥 [content/output: print('hello')]")
        self.assertEqual(pairs[1]['assistant'], "Done!")

    def test_parse_gemini_json(self):
        # Sample Gemini Session Log
        gemini_data = {
            "messages": [
                {
                    "role": "user",
                    "content": "String content"
                },
                {
                    "role": "model",
                    "content": "Model response string"
                },
                {
                    "type": "user",
                    "content": [{"text": "Array content"}]
                },
                {
                    "type": "assistant",
                    "toolCalls": [
                        {"name": "read_file", "args": {"file_path": "bar.txt"}}
                    ]
                },
                {
                    "type": "tool",
                    "toolCalls": [
                        {"name": "read_file", "result": "file contents here"}
                    ]
                },
                {
                    "role": "model",
                    "content": "Done with Gemini!"
                }
            ]
        }
        json_str = json.dumps(gemini_data)
        f = io.StringIO(json_str)
        pairs = parse_session(f, "gemini", pairs_count=3, limit=150)
        self.assertEqual(len(pairs), 3)
        
        # Verify first pair (User: String content -> Assistant: Model response string)
        self.assertEqual(pairs[0]['user'], "String content")
        self.assertEqual(pairs[0]['assistant'], "Model response string")
        
        # Verify second pair (User: Array content -> Assistant: toolCalls)
        self.assertEqual(pairs[1]['user'], "Array content")
        self.assertIn("🛠️ read_file [file_path: bar.txt]", pairs[1]['assistant'])
        
        # Verify third pair (User: tool result output mapped -> Assistant: Done with Gemini!)
        self.assertEqual(pairs[2]['user'], "📥 [content/output: file contents here]")
        self.assertEqual(pairs[2]['assistant'], "Done with Gemini!")

if __name__ == '__main__':
    unittest.main()
