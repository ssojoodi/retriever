#!/usr/bin/env python3
"""Create a branded Finder disk image. Signing/notarization belong to release.py."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('work', type=Path)
    args = parser.parse_args()
    app, output, work = args.app.resolve(), args.output.resolve(), args.work.resolve()
    if not (app / 'Contents/Info.plist').is_file() or app.name != 'Retriever.app':
        raise ValueError('Expected a built Retriever.app bundle.')
    if output.exists():
        raise ValueError('Output already exists; choose a new candidate path.')
    existing = subprocess.run(['osascript', '-e',
        'tell application "Finder" to count (every disk whose name is "Retriever")'],
        check=True, capture_output=True, text=True)
    if int(existing.stdout.strip()) != 0:
        raise RuntimeError('Eject the mounted Retriever disk image before creating a new one.')
    work.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parent.parent
    # Unique staging prevents collision with another release or mounted image.
    root = Path(tempfile.mkdtemp(prefix='layout-', dir=work))
    contents = root / 'contents'
    background = contents / '.background/background.png'
    background.parent.mkdir(parents=True)
    cache = repo / '.build/ModuleCache'
    cache.mkdir(parents=True, exist_ok=True)
    run('xcrun', 'swift', '-module-cache-path', cache, repo / 'Brand/RenderDMGBackground.swift', background)
    run('ditto', app, contents / app.name)
    (contents / 'Applications').symlink_to('/Applications')
    writable = root / 'layout.dmg'
    run('hdiutil', 'create', '-volname', 'Retriever', '-srcfolder', contents,
        '-fs', 'HFS+', '-format', 'UDRW', writable)
    mount = root / 'mounted'
    mount.mkdir()
    attached = False
    try:
        run('hdiutil', 'attach', writable, '-readwrite', '-noautoopen', '-nobrowse', '-mountpoint', mount)
        attached = True
        for hidden in ('.background', '.fseventsd'):
            if (mount / hidden).exists():
                run('chflags', 'hidden', mount / hidden)
        run('osascript', repo / 'scripts/layout_dmg.applescript', mount, app.name)
        if not (mount / '.DS_Store').is_file():
            raise RuntimeError('Finder did not save the disk image layout.')
    finally:
        if attached:
            # A failed detach must leave staging available for recovery.
            try:
                run('hdiutil', 'detach', mount)
            except subprocess.CalledProcessError:
                raise RuntimeError(f'Could not detach {mount}; eject it before cleaning {root}')
    run('hdiutil', 'convert', writable, '-format', 'UDZO', '-imagekey', 'zlib-level=9', '-o', output)
    run('hdiutil', 'verify', output)
    print(f'Branded DMG created: {output}')


if __name__ == '__main__':
    main()
