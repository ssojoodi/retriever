#!/usr/bin/env python3
"""Check release replacement and backup behavior without signing credentials."""
import hashlib
import json
from pathlib import Path
import runpy
import tempfile

publish = runpy.run_path(str(Path(__file__).with_name('release.py')))['publish_release']
with tempfile.TemporaryDirectory() as temporary:
    repo = Path(temporary)
    dmg = repo / 'candidate.dmg'
    dmg.write_bytes(b'first validated candidate')
    checksum = hashlib.sha256(dmg.read_bytes()).hexdigest()
    target = publish(repo, dmg, checksum, '0.1.0')
    assert target == repo / 'web-page/Retriever.dmg'
    assert target.read_bytes() == dmg.read_bytes()
    assert json.loads((target.parent / 'release.json').read_text())['sha256'] == checksum
    dmg.write_bytes(b'second validated candidate')
    checksum = hashlib.sha256(dmg.read_bytes()).hexdigest()
    publish(repo, dmg, checksum, '0.2.0')
    backups = list((repo / 'docs/dmg-backups').glob('*.dmg'))
    assert len(backups) == 1 and backups[0].read_bytes() == b'first validated candidate'
    assert target.read_bytes() == dmg.read_bytes()
    assert (target.parent / 'Retriever.dmg.sha256').read_text() == checksum + '  Retriever.dmg\n'
    metadata = json.loads((target.parent / 'release.json').read_text())
    assert metadata['version'] == '0.2.0' and 'build' not in metadata
    previous_manifest = (target.parent / 'release.json').read_bytes()
    # A missing candidate must never replace the working artifact or metadata.
    dmg.unlink()
    try:
        publish(repo, dmg, 'a' * 64, '0.3.0')
    except FileNotFoundError:
        pass
    else:
        raise AssertionError('Missing candidate was accepted')
    assert target.read_bytes() == b'second validated candidate'
    assert (target.parent / 'release.json').read_bytes() == previous_manifest
    assert not list(target.parent.glob('.release-*'))
print('PASS: web-page publication, timestamped backups, checksum/metadata and failed-copy preservation.')
