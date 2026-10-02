#!/usr/bin/env python3
"""Check release orchestration without signing credentials or Apple submissions."""
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

release = runpy.run_path(str(Path(__file__).with_name('release.py')))
main = release['main']
identity = 'Developer ID Application: Test Developer (ABCDEFGHIJ)'

with tempfile.TemporaryDirectory() as temporary:
    repo = Path(temporary).resolve()
    calls = []
    submissions = []
    failure = None

    def run(*args, capture=False):
        args = tuple(map(str, args))
        calls.append(args)
        if args[0] == 'security':
            return f'"{identity}"'
        if args[:2] == ('xcrun', 'xcodebuild'):
            assert args[args.index('-derivedDataPath') + 1] == str(repo / '.build/release/DerivedData')
            assert 'ARCHS=arm64 x86_64' in args
        elif args[0] == 'ditto':
            app = Path(args[2])
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleShortVersionString': '0.4.0', 'CFBundleVersion': '0.4.0'}))
        elif len(args) > 1 and args[1] == 'scripts/create_dmg.py':
            Path(args[3]).write_bytes(b'validated candidate')
        if failure and args[:len(failure)] == failure:
            raise subprocess.CalledProcessError(1, args)

    def notarize(path, profile, staging, label):
        submissions.append((path, label))
        assert Path(path).suffix == '.dmg' and label == 'dmg'
        if failure == ('notarize',):
            raise RuntimeError('Notarization rejected')

    def metadata(args, **kwargs):
        assert args[:2] == ['codesign', '-d']
        return SimpleNamespace(stderr='TeamIdentifier=ABCDEFGHIJ', stdout=b'')

    original_directory = Path.cwd()
    try:
        with patch.dict(main.__globals__, {'__file__': str(repo / 'scripts/release.py'), 'run': run, 'notarize': notarize}), \
             patch('sys.argv', ['release.py', '--identity', identity, '--profile', 'test-notary']), \
             patch('sys.stdin', io.StringIO()), \
             patch('builtins.input', side_effect=AssertionError('Release must not prompt')), \
             patch('subprocess.run', side_effect=metadata):
            main()
            assert len(submissions) == 1
            target = repo / 'web-page/Retriever.dmg'
            original = target.read_bytes()
            manifest = (target.parent / 'release.json').read_bytes()
            assert json.loads(manifest)['version'] == '0.4.0'
            assert not any(call[0] == 'open' for call in calls)
            # Failed notarization or final validation must not replace the download.
            for failure in [('notarize',), ('xcrun', 'stapler', 'validate'), ('spctl',), ('hdiutil', 'verify')]:
                try:
                    main()
                except (RuntimeError, subprocess.CalledProcessError):
                    pass
                else:
                    raise AssertionError(f'Failure was ignored: {failure}')
                assert target.read_bytes() == original
                assert (target.parent / 'release.json').read_bytes() == manifest
    finally:
        os.chdir(original_directory)

print('PASS: noninteractive release, reusable cache, DMG-only notarization, and failed-release preservation.')
