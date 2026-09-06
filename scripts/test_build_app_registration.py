#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


class BuildAppRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='build-registration-tests-')
        self.root = Path(self.temporary.name).resolve() / 'repo'
        (self.root / 'scripts').mkdir(parents=True)
        self.wrapper = self.root / 'scripts' / 'with_unregistered_build_app.py'
        shutil.copyfile(Path(__file__).with_name(self.wrapper.name), self.wrapper)
        self.app = self.root / 'build' / 'fixture' / 'Build' / 'Products' / 'Debug' / 'SapoWhisper.app'
        self.log = self.root / 'calls.jsonl'
        self.mock = self.root / 'lsregister'
        self.mock.write_text(
            '#!' + sys.executable + '\nimport json, os, sys\n'
            'with open(os.environ["FIXTURE_CALL_LOG"], "a") as handle: handle.write(json.dumps(sys.argv[1:]) + "\\n")\n'
            'raise SystemExit(int(os.environ.get("FIXTURE_LSREGISTER_EXIT", "0")))\n'
        )
        self.mock.chmod(0o700)
        self.query_log = self.root / 'query-calls.txt'
        self.query = self.root / 'registration-query'
        self.query.write_text(
            '#!' + sys.executable + '\nimport os\n'
            'with open(os.environ["FIXTURE_QUERY_LOG"], "a") as handle: handle.write("query\\n")\n'
            'print(os.environ["FIXTURE_QUERY_OUTPUT"])\n'
            'raise SystemExit(int(os.environ.get("FIXTURE_QUERY_EXIT", "0")))\n'
        )
        self.query.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def bundle(self, bundle_id='oli.SapoWhisper', path=None):
        path = path or self.app
        (path / 'Contents').mkdir(parents=True)
        with open(path / 'Contents' / 'Info.plist', 'wb') as handle:
            plistlib.dump({'CFBundleIdentifier': bundle_id}, handle)

    def invoke(self, code='pass', app=None, cleanup_exit=0, query_output=None, query_exit=0):
        environment = os.environ.copy()
        environment['FIXTURE_CALL_LOG'] = str(self.log)
        environment['FIXTURE_LSREGISTER_EXIT'] = str(cleanup_exit)
        environment['FIXTURE_QUERY_LOG'] = str(self.query_log)
        environment['FIXTURE_QUERY_OUTPUT'] = query_output if query_output is not None else json.dumps([str(self.app)])
        environment['FIXTURE_QUERY_EXIT'] = str(query_exit)
        return subprocess.run(
            [sys.executable, str(self.wrapper), '--app', str(app or self.app), '--lsregister', str(self.mock),
             '--registration-query', str(self.query), '--', sys.executable, '-c', code], cwd=self.root, env=environment, capture_output=True, text=True, timeout=10
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_success_unregisters_exact_generated_app_without_deleting_files(self):
        self.bundle()
        before = (self.app / 'Contents' / 'Info.plist').read_bytes()
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(self.calls(), [['-u', str(self.app)]])
        self.assertEqual((self.app / 'Contents' / 'Info.plist').read_bytes(), before)

    def test_failed_command_still_unregisters_and_keeps_original_exit_code(self):
        self.bundle()
        self.assertEqual(self.invoke('raise SystemExit(42)').returncode, 42)
        self.assertEqual(self.calls(), [['-u', str(self.app)]])

    def test_cleanup_failure_fails_success_but_does_not_mask_command_failure(self):
        self.bundle()
        self.assertEqual(self.invoke(cleanup_exit=9).returncode, 1)
        self.assertEqual(self.invoke('raise SystemExit(42)', cleanup_exit=9).returncode, 42)

    def test_already_absent_is_accepted_only_after_independent_query(self):
        self.bundle()
        result = self.invoke(cleanup_exit=1, query_output=json.dumps(['/Applications/SapoWhisper.app']))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [['-u', str(self.app)]])
        self.assertEqual(self.query_log.read_text().splitlines(), ['query'])
        self.assertTrue(self.app.exists())

    def test_empty_successful_query_also_proves_target_absent(self):
        self.bundle()
        self.assertEqual(self.invoke(cleanup_exit=9, query_output='[]').returncode, 0)

    def test_failed_query_cannot_be_treated_as_absence(self):
        self.bundle()
        self.assertEqual(self.invoke(cleanup_exit=1, query_output='[]', query_exit=7).returncode, 1)
        self.assertEqual(self.invoke('raise SystemExit(42)', cleanup_exit=1, query_output='[]', query_exit=7).returncode, 42)

    def test_malformed_query_cannot_be_treated_as_absence(self):
        self.bundle()
        for output in ['not-json', '{}', '["relative/path"]', '[null]']:
            self.assertEqual(self.invoke(cleanup_exit=1, query_output=output).returncode, 1)

    def test_query_detects_symlink_alias_of_still_registered_target(self):
        self.bundle()
        alias = self.root / 'alias.app'
        alias.symlink_to(self.app, target_is_directory=True)
        self.assertEqual(self.invoke(cleanup_exit=1, query_output=json.dumps([str(alias)])).returncode, 1)

    def test_successful_unregister_does_not_need_independent_query(self):
        self.bundle()
        self.assertEqual(self.invoke(query_exit=7).returncode, 0)
        self.assertFalse(self.query_log.exists())

    def test_invalid_plist_never_masks_failed_command_or_unregisters(self):
        self.bundle()
        (self.app / 'Contents' / 'Info.plist').write_bytes(b'<?xml version="1.0"?><plist><dict>')
        self.assertEqual(self.invoke('raise SystemExit(42)').returncode, 42)
        self.assertEqual(self.calls(), [])

    def test_child_signal_status_is_preserved_after_cleanup(self):
        self.bundle()
        result = self.invoke('import os, signal; os.kill(os.getpid(), signal.SIGTERM)')
        self.assertEqual(result.returncode, 143)
        self.assertEqual(self.calls(), [['-u', str(self.app)]])

    def test_missing_product_never_calls_launchservices(self):
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_foreign_bundle_is_never_unregistered(self):
        self.bundle('example.OtherApp')
        self.assertEqual(self.invoke().returncode, 1)
        self.assertEqual(self.calls(), [])
        self.assertTrue(self.app.exists())

    def test_outside_repository_and_canonical_install_are_refused_before_command(self):
        for path in [Path('/Applications/SapoWhisper.app'), self.root / 'outside' / 'SapoWhisper.app']:
            result = self.invoke('raise SystemExit(42)', app=path)
            self.assertEqual(result.returncode, 64)
        self.assertEqual(self.calls(), [])

    def test_symlinked_product_or_build_root_is_refused(self):
        other = Path(self.temporary.name) / 'other' / 'SapoWhisper.app'
        self.bundle(path=other)
        self.app.parent.mkdir(parents=True)
        self.app.symlink_to(other, target_is_directory=True)
        self.assertEqual(self.invoke().returncode, 64)
        self.app.unlink()
        shutil.rmtree(self.root / 'build')
        (self.root / 'build').symlink_to(other.parent, target_is_directory=True)
        self.assertEqual(self.invoke(app=self.root / 'build' / 'SapoWhisper.app').returncode, 64)
        self.assertEqual(self.calls(), [])

    def test_post_command_guard_rejects_a_path_replaced_by_symlink(self):
        self.app.parent.mkdir(parents=True)
        other = Path(self.temporary.name) / 'other' / 'SapoWhisper.app'
        self.bundle(path=other)
        code = f'from pathlib import Path; Path({str(self.app)!r}).symlink_to({str(other)!r}, target_is_directory=True)'
        self.assertEqual(self.invoke(code).returncode, 1)
        self.assertEqual(self.calls(), [])
        self.assertTrue(other.exists())


if __name__ == '__main__':
    unittest.main()
