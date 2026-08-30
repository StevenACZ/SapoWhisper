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

    def test_provider_urls_require_http_or_https_without_private_url_parts(self):
        invalid_urls = (
            "ftp://example.invalid/v1",
            "http://user:password@example.invalid/v1",
            "http://example.invalid/v1?token=secret",
            "http://example.invalid/v1#fragment",
        )
        for value in invalid_urls:
            with self.subTest(value=value):
                with self.assertRaises(REPLAY.ReplayInputError) as raised:
                    REPLAY.validate_provider_url(value, "polish-base-url")
                self.assertIn("Provider URL must use http(s)", str(raised.exception))
                self.assertNotIn(value, str(raised.exception))

        for value in ("http://localhost:8081/v1", "http://127.0.0.1:8081/v1", "http://[::1]:8081/v1"):
            with self.subTest(value=value):
                self.assertTrue(REPLAY.is_loopback_host(REPLAY.validate_provider_url(value, "polish-base-url").hostname))

    def test_remote_polish_is_rejected_before_local_inputs_are_read(self):
        output = io.StringIO()
        arguments = [
            str(SCRIPT),
            "--json",
            "--db",
            "/private/example/history.db",
            "--polish-base-url",
            "https://remote.example.invalid/v1",
            "--polish-model",
            "test-model",
        ]

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(REPLAY, "load_vocabulary") as load_vocabulary,
            mock.patch.object(REPLAY, "fetch_rows") as fetch_rows,
            contextlib.redirect_stderr(output),
        ):
            self.assertEqual(REPLAY.main(), 1)

        load_vocabulary.assert_not_called()
        fetch_rows.assert_not_called()
        self.assertIn("Remote private data requires --allow-remote-private-data.", output.getvalue())
        self.assertNotIn("remote.example.invalid", output.getvalue())
        self.assertNotIn("/private/example/history.db", output.getvalue())

    def test_remote_stt_requires_opt_in_only_when_audio_retranscription_is_enabled(self):
        output = io.StringIO()
        arguments = [
            str(SCRIPT),
            "--json",
            "--db",
            "/private/example/history.db",
            "--polish-model",
            "test-model",
            "--stt-base-url",
            "https://remote.example.invalid/v1",
            "--retranscribe-audio",
        ]

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(REPLAY, "load_vocabulary") as load_vocabulary,
            mock.patch.object(REPLAY, "fetch_rows") as fetch_rows,
            contextlib.redirect_stderr(output),
        ):
            self.assertEqual(REPLAY.main(), 1)

        load_vocabulary.assert_not_called()
        fetch_rows.assert_not_called()
        self.assertIn("Remote private data requires --allow-remote-private-data.", output.getvalue())
        self.assertNotIn("remote.example.invalid", output.getvalue())

    def test_remote_replay_can_be_explicitly_authorized(self):
        output = io.StringIO()
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
            "--polish-base-url",
            "https://remote.example.invalid/v1",
            "--polish-model",
            "test-model",
            "--allow-remote-private-data",
        ]

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(REPLAY, "load_vocabulary", return_value=([], {})),
            mock.patch.object(REPLAY, "fetch_rows", return_value=[row]),
            mock.patch.object(REPLAY, "polish_text", return_value="git commit please"),
            mock.patch.object(REPLAY, "evaluate_guard", return_value=(True, [])),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(REPLAY.main(), 0)

        self.assertEqual(json.loads(output.getvalue())["rows_requested"], 25)

    def test_remote_replay_rejects_plain_http_even_with_opt_in(self):
        output = io.StringIO()
        arguments = [
            str(SCRIPT),
            "--json",
            "--db",
            "/private/example/history.db",
            "--polish-base-url",
            "http://remote.example.invalid/v1",
            "--polish-model",
            "test-model",
            "--allow-remote-private-data",
        ]

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(REPLAY, "load_vocabulary") as load_vocabulary,
            mock.patch.object(REPLAY, "fetch_rows") as fetch_rows,
            contextlib.redirect_stderr(output),
        ):
            self.assertEqual(REPLAY.main(), 1)

        load_vocabulary.assert_not_called()
        fetch_rows.assert_not_called()
        self.assertIn("Remote private data requires HTTPS.", output.getvalue())
        self.assertNotIn("remote.example.invalid", output.getvalue())


if __name__ == "__main__":
    unittest.main()
