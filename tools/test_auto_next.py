"""Fake CLI checks for one-task continuation and all stop conditions."""

import importlib.util
import io
import json
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("auto_next", Path(__file__).with_name("auto-next.py"))
auto_next = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auto_next)


def cli_output(backend, state, session="session_1"):
    reply = "Progress\nAUTO_NEXT_STATUS: " + state
    if backend == "codex":
        events = [
            {"type": "thread.started", "thread_id": session},
            {"type": "item.completed", "item": {"type": "agent_message", "text": reply}},
            {"type": "turn.completed"},
        ]
    elif backend == "opencode":
        events = [
            {"type": "text", "sessionID": session, "part": {"type": "text", "text": reply}},
            {"type": "step_finish", "sessionID": session, "part": {"reason": "stop"}},
        ]
    else:
        events = [{"type": "result", "subtype": "success", "sessionId": session,
                   "stopReason": "end_turn", "finalText": reply}]
    return "\n".join(json.dumps(event) for event in events)


class AutoNextTest(unittest.TestCase):
    def invoke(self, backend, outputs, limit=5):
        responses = [subprocess.CompletedProcess([], code, text, "failure" if code else "")
                     for code, text in outputs]
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            patch.object(auto_next.subprocess, "run", side_effect=responses) as mock_run,
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            status = auto_next.run(backend, "Fix this one issue", Path.cwd(), limit)
        return status, mock_run.call_args_list, stdout.getvalue(), stderr.getvalue()

    def test_each_backend_resumes_only_its_returned_session(self):
        for backend in ("codex", "opencode", "commandcode"):
            with self.subTest(backend=backend):
                status, calls, output, errors = self.invoke(backend, [
                    (0, cli_output(backend, "CONTINUE")),
                    (0, cli_output(backend, "DONE")),
                ])
                self.assertEqual(status, 0)
                self.assertEqual(len(calls), 2)
                self.assertIn("--session" if backend != "codex" else "session_1", calls[1].args[0])
                self.assertIn("Continue the same task", calls[1].kwargs["input"])
                self.assertNotIn("--auto", calls[1].args[0])
                self.assertNotIn("--yolo", calls[1].args[0])
                self.assertIn("AUTO_NEXT_STATUS: DONE", output)
                self.assertEqual(errors, "")

    def test_blocked_and_missing_marker_stop(self):
        for state in ("BLOCKED", "UNKNOWN"):
            with self.subTest(state=state):
                status, calls, _, _ = self.invoke("codex", [(0, cli_output("codex", state))])
                self.assertEqual(status, 2 if state == "BLOCKED" else 1)
                self.assertEqual(len(calls), 1)

    def test_error_and_session_change_stop(self):
        status, calls, _, _ = self.invoke("commandcode", [(8, cli_output("commandcode", "CONTINUE"))])
        self.assertEqual((status, len(calls)), (1, 1))
        status, calls, _, _ = self.invoke("opencode", [
            (0, cli_output("opencode", "CONTINUE")),
            (0, cli_output("opencode", "DONE", "other_session")),
        ])
        self.assertEqual((status, len(calls)), (1, 2))

    def test_missing_completion_and_max_turns_stop(self):
        incomplete = json.dumps({"type": "thread.started", "thread_id": "session_1"})
        status, calls, _, _ = self.invoke("codex", [(0, incomplete)])
        self.assertEqual((status, len(calls)), (1, 1))
        status, calls, _, _ = self.invoke("codex", [(0, cli_output("codex", "CONTINUE"))], limit=1)
        self.assertEqual((status, len(calls)), (2, 1))

    def test_error_result_and_malformed_events_stop(self):
        error_result = json.dumps({"type": "result", "subtype": "error", "finalText": ""})
        status, _, _, errors = self.invoke("commandcode", [(0, error_result)])
        self.assertEqual(status, 1)
        self.assertIn("subtype=error", errors)

        capped = json.dumps({"type": "result", "subtype": "success", "stopReason": "max_turns",
                             "sessionId": "session_1", "finalText": "Progress"})
        status, calls, _, errors = self.invoke("commandcode", [(0, capped)])
        self.assertEqual(status, 1)
        self.assertEqual(len(calls), 1)
        self.assertIn("stopReason=max_turns", errors)

        malformed = "\n".join([
            json.dumps({"type": "thread.started", "thread_id": "session_1"}),
            json.dumps({"type": "item.completed", "item": None}),
            json.dumps({"type": "turn.completed"}),
        ])
        status, _, _, _ = self.invoke("codex", [(0, malformed)])
        self.assertEqual(status, 1)

    def test_launcher_skips_extensionless_shims(self):
        def fake_which(name):
            return "/npm/" + name if name.endswith((".cmd", ".exe")) else None

        with patch.object(auto_next.shutil, "which", side_effect=fake_which):
            self.assertTrue(auto_next.launcher("commandcode").endswith("commandcode.cmd"))
            self.assertTrue(auto_next.launcher("codex").endswith("codex.cmd"))
            self.assertTrue(auto_next.launcher("opencode").endswith("opencode.exe"))

    def test_config_is_bounded(self):
        self.assertEqual(auto_next.max_turns(), 5)

    def test_opencode_reads_the_last_text_part(self):
        first = json.dumps({"type": "text", "sessionID": "session_1",
                            "part": {"type": "text", "text": "Working\nAUTO_NEXT_STATUS: CONTINUE"}})
        done = json.dumps({"type": "text", "sessionID": "session_1",
                           "part": {"type": "text", "text": "All set\nAUTO_NEXT_STATUS: DONE"}})
        plain = json.dumps({"type": "text", "sessionID": "session_1",
                            "part": {"type": "text", "text": "Still talking"}})
        finish = json.dumps({"type": "step_finish", "sessionID": "session_1", "part": {"reason": "stop"}})

        status, calls, output, errors = self.invoke("opencode", [(0, f"{first}\n{done}\n{finish}")])
        self.assertEqual(status, 0)
        self.assertIn("AUTO_NEXT_STATUS: DONE", output)
        self.assertEqual(errors, "")

        status, calls, _, errors = self.invoke("opencode", [(0, f"{first}\n{plain}\n{finish}")])
        self.assertEqual(status, 1)
        self.assertEqual(len(calls), 1)
        self.assertIn("Missing exact AUTO_NEXT_STATUS", errors)

    def test_cli_error_message_is_reported(self):
        output = "\n".join([
            json.dumps({"type": "thread.started", "thread_id": "session_1"}),
            json.dumps({"type": "error", "message": "You've hit your usage limit."}),
            json.dumps({"type": "turn.failed", "error": {"message": "You've hit your usage limit."}}),
        ])
        status, calls, _, errors = self.invoke("codex", [(1, output)])
        self.assertEqual(status, 1)
        self.assertEqual(len(calls), 1)
        self.assertIn("usage limit", errors)


if __name__ == "__main__":
    unittest.main()
