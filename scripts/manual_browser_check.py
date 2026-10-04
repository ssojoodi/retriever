#!/usr/bin/env python3
"""Launch the packaged app against a disposable loopback SFTP server.

Keeps the fixture alive until Retriever quits. Does not edit SSH configuration;
accepting the native trust prompt uses the user's normal known_hosts file.
"""
import argparse
import getpass
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=repo / '.build/DerivedData/Build/Products/Debug/Retriever.app')
    parser.add_argument('--relaunch-once', action='store_true', help='Keep the fixture running for one app relaunch to test saved hosts.')
    parser.add_argument('--shell', action='store_true', help='Allow interactive SSH for terminal checks.')
    args = parser.parse_args()
    app = args.app.resolve() / 'Contents/MacOS/Retriever'
    if not app.is_file():
        raise RuntimeError('Run make build first.')
    checks = repo / '.build/checks'
    checks.mkdir(parents=True, exist_ok=True)
    # Keep the agent socket path short enough for sockaddr_un on macOS.
    with tempfile.TemporaryDirectory(prefix='manual-', dir=checks) as temporary, \
            tempfile.TemporaryDirectory(prefix='retriever-agent-', dir='/tmp') as agent_directory:
        root = Path(temporary)
        server = agent = application = None
        try:
            for name in ('host_key', 'client_key'):
                subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / name)], check=True)
            (root / 'authorized_keys').write_text((root / 'client_key.pub').read_text())
            files = Path(agent_directory) / 'files'
            files.mkdir()
            upload_source = Path(agent_directory) / 'upload-test.txt'
            upload_source.write_text('Uploaded successfully with Retriever.\n')
            upload_folder = Path(agent_directory) / 'Upload folder'
            (upload_folder / 'Nested/Empty').mkdir(parents=True)
            (upload_folder / 'Nested/nested-upload.txt').write_text('Uploaded a nested folder with Retriever.\n')
            (files / 'Empty folder').mkdir()
            (files / 'Examples/Nested').mkdir(parents=True)
            (files / 'Examples/Nested/nested-test.txt').write_text('Retrieved from an expanded folder.\n')
            (files / 'large-preview.txt').write_text('Large preview test.\n' * 100_000)
            with (files / 'cancel-preview.bin').open('wb') as large:
                large.truncate(128 * 1024 * 1024)
            (files / 'retriever-test.txt').write_text('Retrieved successfully with Retriever.\n')
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            config = root / 'sshd_config'
            config.write_text(f'''ListenAddress 127.0.0.1
Port {port}
HostKey "{root}/host_key"
PidFile "{root}/sshd.pid"
AuthorizedKeysFile "{root}/authorized_keys"
AllowUsers {getpass.getuser()}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
DisableForwarding yes
PermitTTY {"yes" if args.shell else "no"}
PermitUserRC no
{("ForceCommand internal-sftp -d " + str(files)) if not args.shell else ""}
Subsystem sftp internal-sftp -d {files}
''')
            subprocess.run(['/usr/sbin/sshd', '-t', '-f', str(config)], check=True)
            environment = dict(os.environ, SSH_AUTH_SOCK=str(Path(agent_directory) / 'agent.sock'),
                               LLVM_PROFILE_FILE=str(checks / 'manual-%p.profraw'))
            with (checks / 'manual-server.log').open('w') as server_log, (checks / 'manual-agent.log').open('w') as agent_log, (checks / 'manual-app.log').open('w') as app_log:
                agent = subprocess.Popen(['/usr/bin/ssh-agent', '-D', '-a', environment['SSH_AUTH_SOCK']], stdout=agent_log, stderr=agent_log)
                deadline = time.monotonic() + 5
                while not Path(environment['SSH_AUTH_SOCK']).exists():
                    if agent.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Temporary SSH agent did not start.')
                    time.sleep(0.05)
                subprocess.run(['/usr/bin/ssh-add', str(root / 'client_key')], env=environment, check=True)
                server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=server_log, stderr=server_log)
                deadline = time.monotonic() + 5
                while True:
                    if server.poll() is not None:
                        raise RuntimeError('Test server exited; see .build/checks/manual-server.log.')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise RuntimeError('Test server did not start.')
                        time.sleep(0.05)
                public_key = (root / 'host_key.pub').read_text().split()
                known_hosts = root / 'preflight-known-hosts'
                known_hosts.write_text(f'[127.0.0.1]:{port} {public_key[0]} {public_key[1]}\n')
                listing = subprocess.run(
                    ['/usr/bin/sftp', '-F', '/dev/null', '-o', 'BatchMode=yes',
                     '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile={known_hosts}',
                     '-P', str(port), f'{getpass.getuser()}@127.0.0.1'],
                    input='ls\nquit\n', capture_output=True, text=True, env=environment,
                    check=True, timeout=10).stdout
                if 'retriever-test.txt' not in listing or 'Empty folder' not in listing:
                    raise RuntimeError('Fixture preflight did not list the sample files.')
                print(f'Server: 127.0.0.1\nUsername: {getpass.getuser()}\nPort: {port}', flush=True)
                subprocess.run(['/usr/bin/ssh-keygen', '-lf', str(root / 'host_key.pub')], check=True)
                print('Download retriever-test.txt. Expected text: Retrieved successfully with Retriever.\nQuit this Retriever instance to stop the fixture and remove temporary keys.', flush=True)
                print(f'Upload fixtures: {upload_source} and {upload_folder}', flush=True)
                for launch in range(2 if args.relaunch_once else 1):
                    if launch:
                        print('Relaunching Retriever with the same server. Open Connection should remember the host and last folder.', flush=True)
                    application = subprocess.Popen([str(app)], env=environment, stdout=app_log, stderr=app_log)
                    code = application.wait()
                    if code:
                        raise RuntimeError(f'Retriever exited with status {code}; see manual-app.log.')
        finally:
            stop(application)
            stop(server)
            stop(agent)
    print('Manual fixture stopped and temporary keys removed.', flush=True)


if __name__ == '__main__':
    main()
