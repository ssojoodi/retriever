# SFTP protocol core

## Summary
Implement binary SFTP v3 directory browsing and file retrieval over a process stream. Use macOS OpenSSH for encryption and authentication; never parse `ls` output or interpolate remote paths into shell commands.

## Product behavior target
Core can negotiate SFTP, resolve a directory, list entries including spaces and Unicode, and retrieve exact bytes. Errors remain explicit. UI integration follows this independently testable milestone.

## Architecture changes
A bounded packet codec and a synchronous session owned by one worker queue. Production launches `/usr/bin/ssh -s … sftp` with batch authentication and strict host verification. Tests use the installed `/usr/libexec/sftp-server` with temporary fixtures, requiring no network or credentials. No SSH cryptography implemented in-app. Reference: https://datatracker.ietf.org/doc/html/draft-ietf-secsh-filexfer-02 .

## UX acceptance criteria
No UI claim of connection until negotiation succeeds. Preserve raw file names in protocol operations. Remote failures must not appear as empty directories or successful downloads. Existing destination files must never be overwritten by this initial download API.

## Automated test plan
Malformed/truncated packet boundaries; 64-bit size and attributes; real local SFTP handshake, canonicalization, directory entries, empty and multi-chunk downloads, missing-file failures and destination preservation. Run full Xcode tests.

## Manual verification plan
This milestone has no UI changes. Next iteration connects the browser and exercises server errors, navigation, transfer cancellation and screenshot verification.

## Assumptions and non-goals
Existing keys/SSH agent and known_hosts for first transport slice. Interactive password/host-trust UI, transfer progress/cancellation integration, timeout handling and packaged release remain follow-up work; this core alone does not complete the user goal.

## Verification result
Unsigned Xcode Debug build and all 11 tests passed (6 new SFTP tests). Real local sftp-server negotiation, canonicalization, directory listing and exact empty/100,000-byte downloads passed, including Unicode, quotes and newline in a filename. Missing-file errors and preservation of an existing destination passed. Result: `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_21-27-16--0400.xcresult`. No remote SSH server or UI integration was exercised; those remain required. No UI changed, so the previous foundation screenshot remains the latest UI evidence.
