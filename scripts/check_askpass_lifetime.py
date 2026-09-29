#!/usr/bin/env python3
"""Verify the packaged askpass process closes its output pipe after parent exit."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

repo = Path(__file__).resolve().parent.parent
if '--parent' in sys.argv:
    app = repo / '.build/DerivedData/Build/Products/Debug/Retriever.app/Contents/MacOS/Retriever'
    environment = dict(os.environ, RETRIEVER_ASKPASS='1',
                       LLVM_PROFILE_FILE=str(repo / '.build/checks/lifetime-%p.profraw'))
    environment.pop('SSH_ASKPASS_PROMPT', None)
    child = subprocess.Popen([str(app), 'Automatic lifetime check. This dialog will close shortly; no input needed.'], env=environment)
    time.sleep(2)
    if child.poll() is not None:
        raise RuntimeError('Helper exited before its parent; lifetime check invalid.')
    print('Parent exiting with helper still active.', flush=True)
    # Child inherits stdout/stderr, so the observer sees EOF only after both exit.
    os._exit(0)

parent = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--parent'],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
try:
    output, errors = parent.communicate(timeout=8)
except subprocess.TimeoutExpired:
    os.killpg(parent.pid, signal.SIGTERM)
    parent.communicate(timeout=5)
    raise RuntimeError('Helper retained the pipe after parent exit.')
if parent.returncode != 0 or output != b'Parent exiting with helper still active.\n':
    raise RuntimeError('Lifetime check did not reach the expected parent exit.')
print('PASS: active packaged askpass helper closed its inherited pipes after parent exit.')
