import json
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest
import urllib.parse

from stt_benchmark_vocabulary import (
    apply_recognition_corrections,
    initial_prompt_text,
    sanitized_recognition_hint,
    score,
    swift_character_count,
)


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
BENCHMARK_SCRIPT = REPO_ROOT / "scripts" / "local_stt_benchmark.sh"
CLOUD_BENCHMARK_SCRIPT = REPO_ROOT / "scripts" / "cloud_stt_benchmark.sh"


class BenchmarkVocabularyParityTests(unittest.TestCase):
    def test_prompt_matches_production_order_toggle_dedup_and_cap(self):
        keyterms = ["AlphaTool", "alphatool", "BetaCLI"]
        replacements = {"heard beta": "BetaCLI", "heard gamma": "GammaAPI"}

        self.assertEqual(
            initial_prompt_text(keyterms, replacements),
            "Glossary: AlphaTool, BetaCLI, GammaAPI.",
        )
        self.assertEqual(
            initial_prompt_text(keyterms, replacements, include_replacement_values=False),
            "Glossary: AlphaTool, BetaCLI.",
        )
        self.assertEqual(initial_prompt_text(keyterms, replacements, max_length=24), "Glossary: AlphaTool.")

    def test_prompt_count_matches_common_swift_unicode_graphemes(self):
        decomposed = "Cafe\u0301"
        family = "👩‍👩‍👧‍👦"
        fixtures = {
            decomposed: 4,
            "工具": 2,
            family: 1,
            "🇵🇪": 1,
            "👍🏽": 1,
        }

        for value, expected in fixtures.items():
            with self.subTest(value=value):
                self.assertEqual(swift_character_count(value), expected)

        self.assertEqual(sanitized_recognition_hint(family), "👩 👩 👧 👦")
        self.assertEqual(initial_prompt_text([decomposed, "工具", family], {}, max_length=20), "Glossary: Café, 工具.")

    def test_unstable_expansion_is_skipped_and_result_is_idempotent(self):
        replacements = {"push": "git push", "get push": "git push", "tool": "Tool"}
        corrected = apply_recognition_corrections("use push, then get push with tool", [], replacements)

        self.assertEqual(corrected, "use push, then git push with Tool")
        self.assertEqual(apply_recognition_corrections(corrected, [], replacements), corrected)

    def test_boundaries_preserve_sentence_period_and_longer_words(self):
        corrected = apply_recognition_corrections(
            "run comit. codexical differs from codex",
            ["commit", "Codex"],
            {},
        )

        self.assertEqual(corrected, "run commit. codexical differs from Codex")

    def test_context_only_words_and_ambiguous_canonical_terms_are_unchanged(self):
        context = "a hit song, a pug, a comet, cloud storage"
        self.assertEqual(apply_recognition_corrections(context, ["git", "git push", "commit", "Claude"], {}), context)
        self.assertEqual(
            apply_recognition_corrections("update legends.md", ["AGENTS.md", "legends.md"], {}),
            "update legends.md",
        )

    def test_specific_multiword_variants_still_correct(self):
        corrected = apply_recognition_corrections(
            "run deep comment, KitPush, and hit pug",
            ["git", "commit", "push", "git push"],
            {},
        )

        self.assertEqual(corrected, "run git commit, git push, and git push")

    def test_score_uses_unicode_wer_and_hard_gates(self):
        result = score(
            "Configura Café工具 dos veces con 12 píxeles y luego 12 más.",
            "Configura Cafe工具 una vez con 1212 píxeles.",
            ["Café工具"],
        )

        self.assertFalse(result["hard_gates_pass"])
        self.assertFalse(result["critical_terms_pass"])
        self.assertFalse(result["digit_runs_pass"])
        self.assertGreater(result["word_error_rate"], 0)
        self.assertNotIn("weighted_score", result)
        self.assertEqual(result["lexicographic_rank"][:2], [1, 1])

    def test_cjk_wer_preserves_ranking_gradient(self):
        partial = score("你好世界", "你好世", [])
        wrong = score("你好世界", "完全错误", [])

        self.assertGreater(partial["word_error_rate"], 0)
        self.assertLess(partial["word_error_rate"], wrong["word_error_rate"])

    def test_unicode_wer_preserves_combining_marks(self):
        result = score("कि", "क", [])

        self.assertGreater(result["word_error_rate"], 0)

    def test_score_preserves_order_multiplicity_sign_and_separators(self):
        passing = score("usa -5, 12.50 y 12", "usa -5, 12,50 y 12", [])
        canonically_equivalent = score("Café", "Cafe\u0301", ["Café"])
        reordered = score("mueve 5 al sprint 6", "mueve 6 al sprint 5", [])
        combined = score("usa 12 y luego 50", "usa 1250", [])
        separator_removed = score("cobra 12.50", "cobra 1250", [])

        self.assertTrue(passing["digit_runs_pass"])
        self.assertTrue(canonically_equivalent["hard_gates_pass"])
        self.assertEqual(canonically_equivalent["word_error_rate"], 0)
        self.assertFalse(reordered["digit_runs_pass"])
        self.assertFalse(combined["digit_runs_pass"])
        self.assertFalse(separator_removed["digit_runs_pass"])

    def test_score_rejects_invented_digits_and_critical_term_occurrences(self):
        result = score("paga 5 con AlphaTerm", "paga 999 y 5 con AlphaTerm AlphaTerm", ["AlphaTerm"])

        self.assertFalse(result["hard_gates_pass"])
        self.assertFalse(result["digit_runs_pass"])
        self.assertFalse(result["critical_terms_pass"])
        self.assertEqual(result["digit_runs_unexpected_occurrences"], 1)
        self.assertEqual(result["critical_terms_unexpected_occurrences"], 1)

    def test_score_invalidates_critical_terms_absent_from_reference(self):
        result = score("Beta", "Beta", ["Alpha"])

        self.assertFalse(result["hard_gates_pass"])
        self.assertFalse(result["critical_terms_fixture_valid"])
        self.assertEqual(result["critical_terms_invalid_fixture_count"], 1)

    def test_local_benchmark_request_contract_and_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            audio = temporary / "sample.wav"
            transcript = temporary / "reference.txt"
            vocabulary = temporary / "vocabulary.json"
            critical = temporary / "critical.txt"
            capture = temporary / "curl-args.json"
            audio.write_bytes(b"RIFFsynthetic")
            transcript.write_text("AlphaTerm 42")
            vocabulary.write_text(json.dumps({"keyterms": ["AlphaTerm"], "replacements": {"heard beta": "BetaCLI"}}))
            critical.write_text("AlphaTerm\n")
            self._write_curl_stub(temporary)

            for language, expected_language in (("es", True), ("auto", False)):
                with self.subTest(language=language):
                    result = subprocess.run(
                        [str(BENCHMARK_SCRIPT)],
                        cwd=REPO_ROOT,
                        env=self._benchmark_environment(temporary, audio, transcript, vocabulary, critical, capture, language),
                        capture_output=True,
                        text=True,
                        check=True,
                    )
                    arguments = json.loads(capture.read_text())
                    forms = [arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value in {"--form", "--form-string"}]
                    output = json.loads(result.stdout)

                    self.assertIn("response_format=json", forms)
                    self.assertIn("vad_filter=true", forms)
                    self.assertIn("model=synthetic-model", forms)
                    self.assertIn("prompt=Glossary: AlphaTerm, BetaCLI.", forms)
                    self.assertTrue(any(value.startswith("file=@") and "filename=recording.wav" in value for value in forms))
                    self.assertEqual("language=es" in forms, expected_language)
                    self.assertNotIn("Synthetic private transcript", result.stdout)
                    self.assertNotIn("AlphaTerm", result.stdout)
                    self.assertNotIn(str(audio), result.stdout)
                    self.assertFalse(output["scores"]["raw"]["hard_gates_pass"])
                    self.assertNotIn("missing_critical_terms", output["scores"]["raw"])
                    self.assertNotIn("missing_digit_runs", output["scores"]["raw"])
                    self.assertNotIn("unexpected_critical_terms", output["scores"]["raw"])
                    self.assertNotIn("unexpected_digit_runs", output["scores"]["raw"])

    def test_local_benchmark_requires_vocabulary_or_explicit_opt_out(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            audio = temporary / "sample.wav"
            capture = temporary / "curl-args.json"
            audio.write_bytes(b"RIFFsynthetic")
            self._write_curl_stub(temporary)
            environment = os.environ.copy()
            environment.update(
                {
                    "BASE_URL": "http://benchmark.invalid",
                    "MODEL_ID": "synthetic-model",
                    "AUDIO_PATH": str(audio),
                    "PATH": f"{temporary}{os.pathsep}{environment['PATH']}",
                    "CURL_CAPTURE": str(capture),
                }
            )

            missing = subprocess.run([str(BENCHMARK_SCRIPT)], cwd=REPO_ROOT, env=environment, capture_output=True, text=True)
            self.assertEqual(missing.returncode, 2)
            self.assertIn("Set VOCABULARY_PATH", missing.stderr)
            self.assertFalse(capture.exists())

            environment["ALLOW_EMPTY_VOCABULARY"] = "1"
            opted_out = subprocess.run([str(BENCHMARK_SCRIPT)], cwd=REPO_ROOT, env=environment, capture_output=True, text=True, check=True)
            arguments = json.loads(capture.read_text())
            forms = [arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value in {"--form", "--form-string"}]
            self.assertFalse(any(value.startswith("prompt=") for value in forms))
            self.assertNotIn("raw_text", json.loads(opted_out.stdout))

            environment["VOCABULARY_PATH"] = str(temporary / "missing.json")
            invalid = subprocess.run([str(BENCHMARK_SCRIPT)], cwd=REPO_ROOT, env=environment, capture_output=True, text=True)
            self.assertEqual(invalid.returncode, 2)
            self.assertIn("Vocabulary file not found", invalid.stderr)

    def test_cloud_deepgram_contract_and_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            audio = temporary / "sample.wav"
            transcript = temporary / "reference.txt"
            vocabulary = temporary / "vocabulary.json"
            critical = temporary / "critical.txt"
            capture = temporary / "curl-args.json"
            audio.write_bytes(b"RIFFsynthetic")
            transcript.write_text("AlphaTerm 42")
            critical.write_text("AlphaTerm\n")
            vocabulary.write_text(
                json.dumps(
                    {
                        "keyterms": ["AlphaTerm"],
                        "replacements": {"heard beta": "BetaCLI", "push": "git push"},
                        "includeReplacementTargetsInRecognitionHints": False,
                    }
                )
            )
            self._write_curl_stub(temporary)
            environment = os.environ.copy()
            environment.update(
                {
                    "ENGINE": "deepgram",
                    "DEEPGRAM_API_KEY": "private-test-key",
                    "AUDIO_PATH": str(audio),
                    "VOCABULARY_PATH": str(vocabulary),
                    "TRANSCRIPT_PATH": str(transcript),
                    "CRITICAL_TERMS_PATH": str(critical),
                    "LANGUAGE": "auto",
                    "PATH": f"{temporary}{os.pathsep}{environment['PATH']}",
                    "CURL_CAPTURE": str(capture),
                    "PRINT_TEXT": "0",
                }
            )
            result = subprocess.run(
                [str(CLOUD_BENCHMARK_SCRIPT)],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
                check=True,
            )
            arguments = json.loads(capture.read_text())
            endpoint = next(value for value in arguments if value.startswith("https://api.deepgram.com/v1/listen?"))
            query = urllib.parse.parse_qs(urllib.parse.urlparse(endpoint).query)
            output = json.loads(result.stdout)

            self.assertEqual(query["model"], ["nova-3"])
            self.assertEqual(query["language"], ["multi"])
            self.assertEqual(query["smart_format"], ["true"])
            self.assertEqual(query["keyterm"], ["AlphaTerm"])
            self.assertEqual(query["replace"], ["heard beta:BetaCLI"])
            self.assertNotIn("Synthetic private transcript", result.stdout)
            self.assertNotIn("AlphaTerm", result.stdout)
            self.assertNotIn(str(audio), result.stdout)
            self.assertNotIn("private-test-key", result.stdout)
            self.assertNotIn("audio_sha256", output)
            self.assertNotIn("text_sha256", output)
            self.assertNotIn("raw_text", output)
            self.assertEqual(output["critical_term_count"], 1)
            self.assertNotIn("critical_terms", output)
            self.assertNotIn("missing_critical_terms", output["scores"]["raw"])
            self.assertNotIn("missing_digit_runs", output["scores"]["raw"])

    def test_cloud_failure_redacts_provider_and_transport_bodies(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            audio = temporary / "sample.wav"
            capture = temporary / "curl-args.json"
            audio.write_bytes(b"RIFFsynthetic")
            stub = temporary / "curl"
            stub.write_text(
                """#!/usr/bin/env python3
import pathlib
import sys

arguments = sys.argv[1:]
output = arguments[arguments.index("--output") + 1]
pathlib.Path(output).write_text("provider echoed PrivateTerm 4242")
print("transport detail PrivateTerm 4242", file=sys.stderr)
raise SystemExit(22)
"""
            )
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            environment = os.environ.copy()
            environment.update(
                {
                    "ENGINE": "deepgram",
                    "DEEPGRAM_API_KEY": "private-test-key",
                    "AUDIO_PATH": str(audio),
                    "ALLOW_EMPTY_VOCABULARY": "1",
                    "PATH": f"{temporary}{os.pathsep}{environment['PATH']}",
                    "CURL_CAPTURE": str(capture),
                }
            )

            result = subprocess.run(
                [str(CLOUD_BENCHMARK_SCRIPT)],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 22)
            self.assertIn("curl_status=22", result.stderr)
            self.assertIn("stderr_bytes=", result.stderr)
            self.assertIn("response_bytes=", result.stderr)
            self.assertNotIn("PrivateTerm", result.stderr)
            self.assertNotIn("4242", result.stderr)

    def test_cloud_elevenlabs_uses_canonical_terms_and_respects_hint_toggle(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            audio = temporary / "sample.wav"
            vocabulary = temporary / "vocabulary.json"
            capture = temporary / "curl-args.json"
            audio.write_bytes(b"RIFFsynthetic")
            vocabulary.write_text(
                json.dumps(
                    {
                        "keyterms": ["AlphaTerm"],
                        "replacements": {"heard beta": "BetaCLI"},
                        "includeReplacementTargetsInRecognitionHints": False,
                    }
                )
            )
            self._write_curl_stub(temporary)
            environment = os.environ.copy()
            environment.update(
                {
                    "ENGINE": "elevenlabs",
                    "ELEVENLABS_API_KEY": "private-test-key",
                    "AUDIO_PATH": str(audio),
                    "VOCABULARY_PATH": str(vocabulary),
                    "LANGUAGE": "auto",
                    "PATH": f"{temporary}{os.pathsep}{environment['PATH']}",
                    "CURL_CAPTURE": str(capture),
                }
            )

            subprocess.run(
                [str(CLOUD_BENCHMARK_SCRIPT)],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
                check=True,
            )
            arguments = json.loads(capture.read_text())
            forms = [
                arguments[index + 1]
                for index, value in enumerate(arguments[:-1])
                if value in {"--form", "--form-string"}
            ]

            self.assertIn("keyterms=AlphaTerm", forms)
            self.assertFalse(any("BetaCLI" in value for value in forms))
            self.assertFalse(any("alpha term" in value.lower() for value in forms))

    def test_cloud_elevenlabs_rejects_invalid_vocabulary_before_curl(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = pathlib.Path(directory)
            audio = temporary / "sample.wav"
            vocabulary = temporary / "vocabulary.json"
            capture = temporary / "curl-args.json"
            audio.write_bytes(b"RIFFsynthetic")
            vocabulary.write_text('{"keyterms":["PrivateTerm"],')
            self._write_curl_stub(temporary)
            environment = os.environ.copy()
            environment.update(
                {
                    "ENGINE": "elevenlabs",
                    "ELEVENLABS_API_KEY": "private-test-key",
                    "AUDIO_PATH": str(audio),
                    "VOCABULARY_PATH": str(vocabulary),
                    "PATH": f"{temporary}{os.pathsep}{environment['PATH']}",
                    "CURL_CAPTURE": str(capture),
                }
            )

            result = subprocess.run(
                [str(CLOUD_BENCHMARK_SCRIPT)],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(capture.exists())
            self.assertNotIn("private-test-key", result.stderr)
            self.assertNotIn("PrivateTerm", result.stderr)

    def _write_curl_stub(self, directory):
        stub = directory / "curl"
        stub.write_text(
            """#!/usr/bin/env python3
import json
import os
import pathlib
import sys

arguments = sys.argv[1:]
pathlib.Path(os.environ["CURL_CAPTURE"]).write_text(json.dumps(arguments))
output = arguments[arguments.index("--output") + 1]
pathlib.Path(output).write_text(json.dumps({
    "text": "Synthetic private transcript 42",
    "results": {"channels": [{"alternatives": [{"transcript": "Synthetic private transcript 42"}]}]},
}))
print("0.125", end="")
"""
        )
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

    def _benchmark_environment(self, directory, audio, transcript, vocabulary, critical, capture, language):
        environment = os.environ.copy()
        environment.update(
            {
                "BASE_URL": "http://benchmark.invalid/v1",
                "MODEL_ID": "synthetic-model",
                "AUDIO_PATH": str(audio),
                "TRANSCRIPT_PATH": str(transcript),
                "VOCABULARY_PATH": str(vocabulary),
                "CRITICAL_TERMS_PATH": str(critical),
                "LANGUAGE": language,
                "PATH": f"{directory}{os.pathsep}{environment['PATH']}",
                "CURL_CAPTURE": str(capture),
                "PRINT_TEXT": "0",
            }
        )
        environment.pop("ALLOW_EMPTY_VOCABULARY", None)
        return environment


if __name__ == "__main__":
    unittest.main()
