#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys

LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
WORKSPACE_QUERY = r'''
import AppKit
import Foundation
let paths = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "oli.SapoWhisper")
    .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
guard let data = try? JSONSerialization.data(withJSONObject: paths) else { exit(1) }
FileHandle.standardOutput.write(data)
'''


def remains_registered(app, query_command):
    result = subprocess.run(query_command, capture_output=True, text=True, check=True, timeout=30)
    paths = json.loads(result.stdout)
    if not isinstance(paths, list) or any(not isinstance(path, str) or not Path(path).is_absolute() for path in paths):
        raise ValueError('invalid independent registration query result')
    target = app.resolve()
    for path in paths:
        candidate = Path(path).resolve()
        if candidate == target:
            return True
        try:
            if candidate.samefile(target):
                return True
        except FileNotFoundError:
            pass
    return False


def generated_app(argument):
    root = Path(__file__).resolve().parent.parent
    app = Path(os.path.abspath(argument))
    build = root / 'build'
    if app.name != 'SapoWhisper.app' or not app.is_relative_to(build):
        raise ValueError('not a generated app inside this repository build directory')
    current = root
    for component in app.relative_to(root).parts + ('Contents', 'Info.plist'):
        current = current / component
        if current.is_symlink():
            raise ValueError('symlink in generated app path')
    return app


def unregister(argument, lsregister, query_command):
    app = generated_app(argument)
    if not app.exists():
        return
    if not app.is_dir():
        raise ValueError('generated app is not a directory')
    with open(app / 'Contents' / 'Info.plist', 'rb') as handle:
        info = plistlib.load(handle)
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') != 'oli.SapoWhisper':
        raise ValueError('generated app has an unexpected bundle identifier')
    result = subprocess.run([lsregister, '-u', str(app)], capture_output=True, text=True)
    if result.returncode == 0:
        return
    if remains_registered(app, query_command):
        raise RuntimeError('generated app remains registered after unregister failure')
    print('build registration cleanup: target absence independently verified')


def main():
    parser = argparse.ArgumentParser(description='Run a build command, then unregister its generated app copy.')
    parser.add_argument('--app', required=True)
    parser.add_argument('--lsregister', default=LSREGISTER)
    parser.add_argument('--registration-query', help='Fixture executable returning registered application paths as JSON')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a command is required after --')
    try:
        generated_app(args.app)
    except ValueError as error:
        print(f'build registration cleanup: {error}', file=sys.stderr)
        return 64
    child = None
    interrupted = None
    def forward(signum, _frame):
        nonlocal interrupted
        interrupted = signum
        if child is not None:
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass
    handlers = {item: signal.signal(item, forward) for item in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    result = 127
    try:
        child = subprocess.Popen(command, start_new_session=True)
        if interrupted is not None:
            forward(interrupted, None)
        result = child.wait()
        if result < 0:
            result = 128 - result
        if interrupted is not None and result == 0:
            result = 128 + interrupted
    except OSError:
        print('build registration cleanup: command could not start', file=sys.stderr)
    finally:
        try:
            query_command = [args.registration_query] if args.registration_query else ['/usr/bin/xcrun', 'swift', '-e', WORKSPACE_QUERY]
            unregister(args.app, args.lsregister, query_command)
        except Exception as error:
            print(f'build registration cleanup failed: {type(error).__name__}', file=sys.stderr)
            if result == 0:
                result = 1
        for item, handler in handlers.items():
            signal.signal(item, handler)
    return result


if __name__ == '__main__':
    raise SystemExit(main())
