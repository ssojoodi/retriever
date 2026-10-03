#!/usr/bin/env python3
"""Local Developer ID release. Never uploads a website or changes signing setup."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], check=True,
                            stdout=subprocess.PIPE if capture else None, text=capture)
    return result.stdout if capture else None


def credentials(identity, profile):
    match = re.fullmatch(r'Developer ID Application: .+ \(([A-Z0-9]{10})\)', identity)
    if not match or any(word in identity for word in ('YOUR_', 'Existing Developer', 'TEAMID')):
        raise ValueError('Set SIGN_IDENTITY to your existing Developer ID Application identity in release.env.')
    if not profile or any(word in profile for word in ('YOUR_', 'EXAMPLE')):
        raise ValueError('Set NOTARY_PROFILE to a verified existing Keychain profile in release.env.')
    return match.group(1)


def notarize(path, profile, staging, label):
    report = staging / (label + '-submission.json')
    with report.open('w') as output:
        result = subprocess.run(['xcrun', 'notarytool', 'submit', str(path), '--keychain-profile', profile,
                                 '--wait', '--output-format', 'json'], stdout=output)
    response = json.loads(report.read_text())
    if result.returncode != 0 or response.get('status') != 'Accepted':
        if response.get('id'):
            subprocess.run(['xcrun', 'notarytool', 'log', response['id'], str(staging / (label + '-notary-log.json')),
                            '--keychain-profile', profile], check=False)
        raise RuntimeError(f'{label} notarization did not return Accepted. See {report}')


def publish_release(repo, dmg, checksum, version):
    """Publish a validated candidate locally; keep backups outside the website."""
    website = repo / 'web-page'
    website.mkdir(exist_ok=True)
    target = website / 'Retriever.dmg'
    if target.exists():
        backups = repo / 'docs/dmg-backups'
        backups.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S-%f')
        shutil.copy2(target, backups / f'Retriever-{stamp}.dmg')
        for name in ('Retriever.dmg.sha256', 'release.json'):
            if (website / name).is_file():
                shutil.copy2(website / name, backups / f'{stamp}-{name}')
    with tempfile.TemporaryDirectory(prefix='.release-', dir=website) as temporary:
        prepared = Path(temporary)
        shutil.copy2(dmg, prepared / target.name)
        (prepared / 'Retriever.dmg.sha256').write_text(checksum + '  Retriever.dmg\n')
        (prepared / 'release.json').write_text(json.dumps({
            'version': version, 'file': 'Retriever.dmg',
            'sha256': checksum, 'bytes': dmg.stat().st_size,
            'published': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }, indent=2) + '\n')
        # All candidate files are prepared before replacing the old download.
        for name in (target.name, 'Retriever.dmg.sha256', 'release.json'):
            os.replace(prepared / name, website / name)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', default='')
    parser.add_argument('--profile', default='')
    args = parser.parse_args()
    team = credentials(args.identity, args.profile)
    repo = Path(__file__).resolve().parent.parent
    os.chdir(repo)
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', capture=True)
    if f'"{args.identity}"' not in identities:
        raise RuntimeError('The configured identity is not currently available in the signing Keychain.')
    release_root = repo / '.build/release'
    release_root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='run-', dir=release_root))
    print(f'Release evidence: {staging}', flush=True)
    derived = release_root / 'DerivedData'
    run('xcrun', 'xcodebuild', '-project', 'Retriever.xcodeproj', '-scheme', 'Retriever',
        '-configuration', 'Release', '-destination', 'generic/platform=macOS', '-derivedDataPath', derived,
        'CODE_SIGNING_ALLOWED=NO', 'SWIFT_OPTIMIZATION_LEVEL=-Osize', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'build')
    # Keep the reusable build cache unsigned; sign an isolated copy for this run.
    app = staging / 'Retriever.app'
    run('ditto', derived / 'Build/Products/Release/Retriever.app', app)
    run('bash', 'scripts/verify_release.sh', app)
    # Preserve matching symbols per release, outside the app and DMG.
    for symbols in ('Retriever.app.dSYM', 'RetrieverCore.framework.dSYM'):
        run('ditto', derived / 'Build/Products/Release' / symbols, staging / 'symbols' / symbols)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or info['CFBundleVersion'] != version:
        raise RuntimeError('The app version must use X.Y.Z, and its internal bundle version must match.')
    core = app / 'Contents/Frameworks/RetrieverCore.framework'
    for code in (core, app):
        run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', args.identity, code)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    metadata = subprocess.run(['codesign', '-d', '--verbose=4', str(app)], capture_output=True, text=True, check=True)
    if f'TeamIdentifier={team}' not in metadata.stderr:
        raise RuntimeError('Signed app TeamIdentifier does not match the selected identity.')
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True).stdout
    if entitlements.strip() and plistlib.loads(entitlements).get('com.apple.security.get-task-allow', False):
        raise RuntimeError('Release app has the debug get-task-allow entitlement.')
    dmg = staging / f'Retriever-{version}.dmg'
    run(sys.executable, 'scripts/create_dmg.py', app, dmg, staging / 'dmg-layout')
    run('codesign', '--force', '--timestamp', '--sign', args.identity, dmg)
    notarize(dmg, args.profile, staging, 'dmg')
    run('xcrun', 'stapler', 'staple', dmg)
    run('xcrun', 'stapler', 'validate', dmg)
    run('codesign', '--verify', '--verbose=2', dmg)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
    run('hdiutil', 'verify', dmg)
    digest = hashlib.sha256()
    with dmg.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    checksum = digest.hexdigest()
    (staging / 'sha256.txt').write_text(checksum + '  ' + dmg.name + '\n')
    target = publish_release(repo, dmg, checksum, version)
    print(f'Validated local release: {target}\nSHA-256: {checksum}\nReady to upload web-page/.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, subprocess.CalledProcessError, OSError, EOFError) as error:
        print(f'Release failed: {error}', file=sys.stderr)
        sys.exit(1)
