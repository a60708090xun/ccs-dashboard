#!/usr/bin/env python3
"""Unit tests for ccs_collect.py: check_claude_archived."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from ccs_collect import check_claude_archived, get_claude_version, process_claude_file


def _write_jsonl(path, lines):
    with open(path, 'w') as f:
        for line in lines:
            f.write(json.dumps(line, separators=(',', ':')) + '\n')


ASSISTANT_DONE = {"type": "assistant", "message": {"content": [{"type": "text", "text": "done"}]}, "timestamp": "2026-06-20T10:00:00Z"}
CAVEAT = {"type": "user", "message": {"content": "<local-command-caveat>Caveat</local-command-caveat>"}, "timestamp": "2026-06-20T10:00:01Z"}
EXIT_CMD = {"type": "user", "message": {"content": "<command-name>/exit</command-name> <command-message>exit</command-message>"}, "timestamp": "2026-06-20T10:00:02Z"}


def _exit_stdout(farewell):
    return {"type": "user", "message": {"content": f"<local-command-stdout>{farewell}</local-command-stdout>"}, "timestamp": "2026-06-20T10:00:03Z"}


class TestCheckClaudeArchived(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def _path(self, name):
        return os.path.join(self.tmp, name + '.jsonl')

    def test_exit_goodbye(self):
        p = self._path('exit_goodbye')
        _write_jsonl(p, [ASSISTANT_DONE, CAVEAT, EXIT_CMD, _exit_stdout('Goodbye!')])
        self.assertTrue(check_claude_archived(p))

    def test_exit_see_ya(self):
        p = self._path('exit_see_ya')
        _write_jsonl(p, [ASSISTANT_DONE, CAVEAT, EXIT_CMD, _exit_stdout('See ya!')])
        self.assertTrue(check_claude_archived(p))

    def test_exit_bye(self):
        p = self._path('exit_bye')
        _write_jsonl(p, [ASSISTANT_DONE, CAVEAT, EXIT_CMD, _exit_stdout('Bye!')])
        self.assertTrue(check_claude_archived(p))

    def test_exit_catch_you_later(self):
        p = self._path('exit_catch_you_later')
        _write_jsonl(p, [ASSISTANT_DONE, CAVEAT, EXIT_CMD, _exit_stdout('Catch you later!')])
        self.assertTrue(check_claude_archived(p))

    def test_abrupt_end_not_archived(self):
        p = self._path('abrupt')
        _write_jsonl(p, [
            ASSISTANT_DONE,
            {"type": "system", "subtype": "stop_hook_summary", "timestamp": "2026-06-20T10:00:01Z"},
        ])
        self.assertFalse(check_claude_archived(p))

    def test_resumed_after_exit_not_archived(self):
        p = self._path('resumed')
        _write_jsonl(p, [
            ASSISTANT_DONE, CAVEAT, EXIT_CMD, _exit_stdout('Bye!'),
            {"type": "user", "message": {"content": "actually keep going"}, "timestamp": "2026-06-20T10:05:00Z"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "resuming"}]}, "timestamp": "2026-06-20T10:05:01Z"},
        ])
        self.assertFalse(check_claude_archived(p))

    def test_last_prompt_no_resume_archived(self):
        p = self._path('last_prompt')
        _write_jsonl(p, [
            ASSISTANT_DONE,
            {"type": "last-prompt", "timestamp": "2026-06-20T10:00:01Z"},
        ])
        self.assertTrue(check_claude_archived(p))

    def test_empty_file_not_archived(self):
        p = self._path('empty')
        open(p, 'w').close()
        self.assertFalse(check_claude_archived(p))


class TestGetClaudeVersion(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def _path(self, name):
        return os.path.join(self.tmp, name + '.jsonl')

    def test_version_on_first_event(self):
        p = self._path('has_version')
        _write_jsonl(p, [
            {"type": "user", "message": {"content": "hello"}, "version": "2.1.185"},
        ])
        self.assertEqual(get_claude_version(p), "2.1.185")

    def test_version_on_later_event(self):
        p = self._path('version_later')
        _write_jsonl(p, [
            {"type": "system", "subtype": "init"},
            {"type": "user", "message": {"content": "hello"}, "version": "2.1.177"},
        ])
        self.assertEqual(get_claude_version(p), "2.1.177")

    def test_no_version_field(self):
        p = self._path('no_version')
        _write_jsonl(p, [{"type": "user", "message": {"content": "hello"}}])
        self.assertIsNone(get_claude_version(p))

    def test_empty_file(self):
        p = self._path('empty')
        open(p, 'w').close()
        self.assertIsNone(get_claude_version(p))

    def test_only_first_20_lines_scanned(self):
        p = self._path('version_deep')
        lines = [{"type": "user", "message": {"content": f"msg{i}"}} for i in range(21)]
        lines[20]["version"] = "2.1.999"  # line 21 (0-indexed), beyond scan window
        _write_jsonl(p, lines)
        self.assertIsNone(get_claude_version(p))


class TestProcessClaudeFileVersion(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.proj_dir = os.path.join(self.tmp, 'myproject')
        os.makedirs(self.proj_dir)

    def _path(self, name):
        return os.path.join(self.proj_dir, name + '.jsonl')

    def test_version_included_in_result(self):
        p = self._path('sess1')
        _write_jsonl(p, [
            {"type": "user", "message": {"content": "hi"}, "version": "2.1.185",
             "timestamp": "2026-01-01T00:00:00Z"},
        ])
        result = process_claude_file(p)
        self.assertIsNotNone(result)
        self.assertEqual(result['version'], '2.1.185')

    def test_missing_version_is_empty_string(self):
        p = self._path('sess2')
        _write_jsonl(p, [
            {"type": "user", "message": {"content": "hi"},
             "timestamp": "2026-01-01T00:00:00Z"},
        ])
        result = process_claude_file(p)
        self.assertIsNotNone(result)
        self.assertEqual(result['version'], '')


if __name__ == '__main__':
    unittest.main()
