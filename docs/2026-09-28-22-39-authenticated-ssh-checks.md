# Authenticated SSH checks

## Summary
Verify the real SSH transport with an isolated local OpenSSH server, generated credentials and pinned host keys.

## Product behavior target
The same client arguments used by Retriever negotiate SFTP through authenticated SSH, browse and download exact bytes. Unknown/changed host keys and unauthorized client keys must fail.

## Architecture changes
Add a standalone Swift transport check runner and Python fixture lifecycle driver. `make check-ssh` builds Debug and runs loopback-only sshd with read-only SFTP forced. Keys, fixtures and logs live in a temporary directory under .build and are removed on exit. No changes to ~/.ssh or system sshd configuration. OpenSSH configuration reference: https://man.openbsd.org/sshd_config .

## UX acceptance criteria
No host verification bypass. Fixture keys are disposable; no personal credentials needed. Failures must be distinct diagnostics.

## Automated test plan
Authenticate, negotiate SFTP, list folder and retrieve a multi-chunk file. Verify exact data, unknown-host rejection, changed-host rejection and unauthorized-key rejection. Always terminate the fixture server.

## Manual verification plan
This tests the actual transport, not the complete GUI. Authenticated UI actions and interactive credentials remain pending.

## Assumptions and non-goals
Use installed macOS sshd without root. Docker is unavailable. Unprivileged macOS sshd emits a BSM audit warning but a live-stream handshake succeeded; do not suppress or change system audit configuration.

## Evidence
- Unsigned Xcode Debug build passed.
- `python3 scripts/check_ssh.py` passed: authenticated negotiation, canonical path and listing, exact 131,328-byte download, unknown-host rejection, changed-host rejection, unauthorized client-key rejection.
- Initial check assumed a forced SFTP start directory that was not applied as expected. The final fixture uses read-only SFTP and requests its known absolute fixture directory explicitly.
- The managed fixture exited and cleaned its temporary directory. The earlier exploratory sshd process was terminated and its live handle reported exit 0.
- This establishes real SSH transport behavior, not GUI acceptance or interactive password/trust prompts.
