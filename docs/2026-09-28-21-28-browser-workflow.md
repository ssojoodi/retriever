# Browser workflow

## Summary
Connect the SFTP core to the native browser, with a dedicated worker, navigation, retrieval and cancellation.

## Product behavior target
Connect using existing SSH keys/agent and trusted hosts, browse folders, choose a destination and retrieve one file. Show failures and a busy state. Cancel disconnects the session and removes partial output.

## Architecture changes
Actor isolated session with a dedicated serial executor. A lock-protected cancellation signal is the only cross-thread mutable value. Poll process output with cancellation checks and an idle timeout. MainWindowController owns native table, path and status. Quit/close confirms cancellation while busy.

## UX acceptance criteria
Native table with Name, Size and Modified columns; double-click folder navigation; Up, Refresh, Download and Disconnect actions; disabled actions during work. Save panel cancellation is harmless. Errors are visible. Keep remote paths as bytes.

## Automated test plan
Retain full protocol tests. Add cancelled and stalled operation tests. Compile Swift 6 without broad unsafe isolation annotations.

## Manual verification plan
Launch the built app, inspect screenshot and window sizing. Exercise connection errors and native actions; authenticated end-to-end SSH and AppKit integration checks remain required after this iteration if no fixture is ready.

## Assumptions and non-goals
Password and first-use trust prompts are next authentication iteration. No uploads, FTP or recursive directory download yet. Cancellation deliberately disconnects to discard any partially received protocol response.

## Verification evidence and remaining work
- Unsigned Debug Xcode test command passed all 13 tests. New tests verify cancelling a stalled handshake and timing out a stalled handshake; existing real SFTP list/download cases still pass.
- Result: `.build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_21-35-50--0400.xcresult`.
- Launched exact built Retriever.app and inspected `artifacts/verification/browser-window.png`: toolbar labels and disabled states, empty state, status and window title render correctly.
- Connected table, native panel interactions, minimum size and authenticated SSH UI workflow are not yet manually verified. No claim of full bootstrap completion.
- Remaining refinements: cancelling from close/quit currently cancels work and requires a second close/quit after cleanup; write-side cancellation, diagnostic stderr capture, safe symlink navigation, progress feedback and AppKit workflow checks need follow-up.
