#!/usr/bin/env python3
"""Manually verify the packaged native authentication helper with a dummy value."""
import os
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parent.parent
executable = repo / '.build/DerivedData/Build/Products/Debug/Retriever.app/Contents/MacOS/Retriever'
environment = dict(os.environ, RETRIEVER_ASKPASS='1',
                   LLVM_PROFILE_FILE=str(repo / '.build/checks/manual-askpass-%p.profraw'))
environment.pop('SSH_ASKPASS_PROMPT', None)
for prompt, expected_code, expected_output in [
    ('Retriever verification: enter retriever-test, then click Continue.', 0, b'retriever-test\n'),
    ('Retriever verification: click Cancel. Do not enter a real password.', 1, b''),
]:
    print(prompt, flush=True)
    result = subprocess.run([str(executable), prompt], env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if result.returncode != expected_code or result.stdout != expected_output:
        raise RuntimeError('Native authentication check failed; entered text is intentionally not logged.')
    print('PASS: expected response and exit status; entered text not logged.', flush=True)
print('PASS: packaged native passphrase response and cancellation.', flush=True)
