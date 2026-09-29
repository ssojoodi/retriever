#!/usr/bin/env python3
"""Disposable loopback SSH fixture. Does not modify personal or system SSH config."""
import getpass
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
os.chdir(repo)
products = (Path(sys.argv[1] if len(sys.argv) > 1 else '.build/DerivedData') / 'Build/Products/Debug').resolve()
checks = repo / '.build/checks'
checks.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-F', str(products),
                '-framework', 'RetrieverCore', '-Xlinker', '-rpath', '-Xlinker', str(products),
                'Tests/RetrieverSSHChecks/SSHChecks.swift', '-o', str(checks / 'SSHChecks')], check=True)
with tempfile.TemporaryDirectory(prefix='ssh-', dir=checks) as temporary:
    root = Path(temporary)
    for name in ('host_key', 'client_key'):
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / name)], check=True)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    (root / 'files').mkdir()
    (root / 'files/payload.bin').write_bytes(bytes(range(256)) * 513)
    for name, key in [('known_hosts', 'host_key'), ('changed_hosts', 'client_key')]:
        public = (root / (key + '.pub')).read_text().split()
        (root / name).write_text(f'[127.0.0.1]:{port} {public[0]} {public[1]}\n')
    (root / 'empty_hosts').touch()
    config = root / 'sshd_config'
    config.write_text(f'''ListenAddress 127.0.0.1
Port {port}
HostKey "{root}/host_key"
PidFile "{root}/sshd.pid"
AuthorizedKeysFile "{root}/client_key.pub"
AllowUsers {getpass.getuser()}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
DisableForwarding yes
PermitTTY no
PermitUserRC no
ForceCommand internal-sftp -R
Subsystem sftp internal-sftp
''')
    subprocess.run(['/usr/sbin/sshd', '-t', '-f', str(config)], check=True)
    with (root / 'server.log').open('wb') as log:
        server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                if server.poll() is not None:
                    raise RuntimeError((root / 'server.log').read_text())
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Fixture did not start')
                    time.sleep(0.05)
            environment = dict(os.environ, LLVM_PROFILE_FILE=str(checks / 'ssh-%p.profraw'))
            subprocess.run([str(checks / 'SSHChecks'), str(root), str(port), getpass.getuser()], env=environment, check=True, timeout=45)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
