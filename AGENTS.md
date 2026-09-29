# Retriever

Native macOS SFTP file browser and retrieval utility, inspired by Cyberduck's simplicity.

## Product contract
- Display and internal name: Retriever. AppKit and Swift 6; macOS 14 minimum.
- Primary workflow: connect to an SFTP server, browse folders, and download a selected file.
- First usable slice: one connection, directory navigation, one download with cancellation and visible errors.
- Bundle identifiers: `ca.sahand.Retriever`, `ca.sahand.RetrieverCore`, `ca.sahand.RetrieverCoreTests`. Inferred personal namespace; confirm before distribution.
- One retained window; closing the last window quits. Follow system light/dark appearance.
- Connection and selection state are transient initially. Never persist passwords. Explicitly accepted server keys persist in OpenSSH known_hosts. Closing ends the connection; active transfers must offer cancellation before termination.
- Direct Developer ID distribution, separately signed and notarized DMG. Intended universal arm64/x86_64 release; only claim support after verifying both architectures.
- Initial non-goals: FTP, uploads, remote deletion, synchronization, tabs, bookmarks, website, App Store.
- No license grant selected yet; do not copy a reference project's license.

## Layout and commands
Xcode is authoritative. `Sources/RetrieverApp` owns UI; `Sources/RetrieverCore` owns testable connection and transfer behavior; `Tests/RetrieverCoreTests` owns XCTest cases. Explicit project membership is required for new files.
`make build`, `make test`, `make check-windows`, `make check-ssh`, `make check-browser`, `make run`, `make assets`, `make paths`, `make help`.
Generated output: `.build/`; inspected screenshots: `artifacts/verification/`; iteration plans: `docs/`.
Shared version and signing settings live in `Config/Signing.xcconfig`. Local credentials remain ignored. Unsigned development works without release credentials. Release pipeline is a later milestone and must not report success until signing/notarization and DMG validation pass.

## Working rules
- Implement the smallest coherent product slice first, then complete the requested workflow.
- Prefer native APIs and direct state changes over speculative abstractions.
- Preserve user work and avoid unrelated changes.
- Add focused tests for independently fallible behavior.
- Verify UI changes in the actual built app and inspect screenshot evidence.
- Keep credentials local, plans tracked, generated output isolated.
- Keep commands and this memory current as architecture changes.
- Create a new timestamped plan for every iteration. Commit finished milestones with short messages.

## SFTP core
`SFTPPacket.swift` implements bounded SFTP v3 decoding; `SFTPSession.swift` owns a synchronous process stream and must be used on one dedicated worker, never the main thread. Production uses system SSH with explicit new-host confirmation and rejection of changed keys. UI supplies the app executable as an askpass helper; headless callers use strict batch key/agent authentication. Test injection launches local sftp-server. Remote filenames retain raw bytes. Download publication uses an exclusively created sibling temporary file and non-replacing renamex_np(RENAME_EXCL). Never fall back to a replacing rename. `SFTPBrowser` owns the session on an actor with a dedicated Dispatch executor. UI operations pass a lock-protected cancellation signal; reads and writes poll every 100 ms and have a 30-second idle timeout. Cancelling disconnects the session. SSH diagnostic stderr is drained nonblockingly and capped at 16 KiB for transient error display. The app has an isolated `SSHAskpass` mode for native fingerprint/password/passphrase prompts. Credentials go only to the SSH stdout pipe. Helper exits when its parent SSH exits; negotiation allows five minutes.

## Brand assets
`Brand/RenderIcon.swift` is the editable AppKit vector icon source. `make assets` regenerates all ten tracked PNG slots and catalog metadata deterministically. Ordinary Xcode and Make builds consume tracked assets.

`make check-ssh` builds and tests the actual SSH transport against a disposable loopback sshd. It uses the same `SFTPSession.sshArguments` as production, with test-only identity and known-host paths. No personal/server credentials or SSH configuration changes are needed. Keep network integration separate from core XCTest.

`make check-browser` compiles production AppKit controller sources and uses an internal session factory to isolate fixture credentials. It verifies native connection/navigation and selected-file retrieval with an explicit destination; it does not prove native save confirmation or packaged-app authentication. `retrieveSelection(to:)` is shared by the save callback and the integration runner.
