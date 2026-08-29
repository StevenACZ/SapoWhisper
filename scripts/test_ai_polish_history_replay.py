import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("ai_polish_history_replay.py")
SPEC = importlib.util.spec_from_file_location("ai_polish_history_replay", SCRIPT)
REPLAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPLAY)


class HistoryReplayRedactionTests(unittest.TestCase):
    def run_replay(self, print_samples=False):
        row = {
            "id": 7,
            "raw_transcription": "deep comment please",
            "transcription": "deep comment please",
            "audio_path": None,
        }
        arguments = [
            str(SCRIPT),
            "--json",
            "--db",
            "/private/example/history.db",
            "--polish-model",
            "test-model",
        ]
        if print_samples:
            arguments.append("--print-samples")

        output = io.StringIO()
        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(REPLAY, "load_vocabulary", return_value=([], {})),
            mock.patch.object(REPLAY, "fetch_rows", return_value=[row]),
            mock.patch.object(REPLAY, "polish_text", return_value="git commit please"),
            mock.patch.object(REPLAY, "evaluate_guard", return_value=(True, [])),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(REPLAY.main(), 0)
        return output.getvalue(), json.loads(output.getvalue())

    def test_default_json_contains_only_aggregate_suggestion_counts(self):
        raw_output, result = self.run_replay()

        self.assertEqual(result["history_source"], "local")
        self.assertEqual(result["suggestion_pair_count"], 1)
        self.assertNotIn("history_db", result)
        self.assertNotIn("suggestions", result)
        self.assertNotIn("deep comment", raw_output)
        self.assertNotIn("git commit", raw_output)
        self.assertNotIn("/private/example", raw_output)

    def test_private_sample_opt_in_includes_reviewable_details(self):
        _, result = self.run_replay(print_samples=True)

        self.assertEqual(result["history_db"], "/private/example/history.db")
        self.assertEqual(result["suggestions"][0]["from"], "deep comment")

    def test_polish_model_is_required(self):
        output = io.StringIO()
        arguments = [str(SCRIPT), "--json", "--db", "/private/example/history.db"]

        with (
            mock.patch.object(sys, "argv", arguments),
            contextlib.redirect_stderr(output),
        ):
            with self.assertRaises(SystemExit) as raised:
                REPLAY.parse_args()

        self.assertEqual(raised.exception.code, 2)
        self.assertIn("--polish-model", output.getvalue())
        self.assertNotIn("qwen3.6", output.getvalue())

    def test_default_startup_errors_do_not_expose_local_paths(self):
        output = io.StringIO()
        arguments = [
            str(SCRIPT),
            "--json",
            "--db",
            "/private/example/missing-history.db",
            "--polish-model",
            "test-model",
        ]

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(REPLAY, "load_vocabulary", return_value=([], {})),
            contextlib.redirect_stderr(output),
        ):
            self.assertEqual(REPLAY.main(), 1)

        self.assertIn("Unable to read local replay inputs.", output.getvalue())
        self.assertNotIn("/private/example/missing-history.db", output.getvalue())

    def test_private_startup_error_opt_in_includes_exact_path(self):
        output = io.StringIO()
        arguments = [
            str(SCRIPT),
            "--json",
            "--db",
            "/private/example/missing-history.db",
            "--polish-model",
            "test-model",
            "--print-samples",
        ]

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(REPLAY, "load_vocabulary", return_value=([], {})),
            contextlib.redirect_stderr(output),
        ):
            self.assertEqual(REPLAY.main(), 1)

        self.assertIn("History DB not found: /private/example/missing-history.db", output.getvalue())


if __name__ == "__main__":
    unittest.main()
