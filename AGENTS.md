# Retriever

Native macOS SFTP file browser and retrieval utility, inspired by Cyberduck's simplicity.

## Product contract
- Display and internal name: Retriever. AppKit and Swift 6; macOS 14 minimum.
- Primary workflow: connect to an SFTP server, browse folders, and download a selected file.
- First usable slice: one connection, directory navigation, one download with cancellation and visible errors.
- Bundle identifiers: `ca.sahand.Retriever`, `ca.sahand.RetrieverCore`, `ca.sahand.RetrieverCoreTests`. Inferred personal namespace; confirm before distribution.
- One retained browser window, plus auxiliary Help, Downloads, and file Preview windows; closing the last window quits. Follow system light/dark appearance.
- Successful hosts (server, username, port) and the last visited remote folder persist locally in UserDefaults. Selection remains transient; do not connect automatically on launch. Never persist passwords. Explicitly accepted server keys persist in OpenSSH known_hosts. Closing ends the connection; active transfers must offer cancellation before termination.
- Direct Developer ID distribution, separately signed and notarized DMG. Universal arm64/x86_64 Release compilation and binary slices verified. Intel runtime remains untested.
- Initial non-goals: FTP, uploads, remote deletion, synchronization, tabs, named bookmarks, App Store. A static download website is now maintained in `web-page/`.
- MIT licensed; see LICENSE. Copyright 2026 Sahand Sojoodi. Public repository: https://github.com/ssojoodi/retriever.

## Layout and commands
Xcode is authoritative. `Sources/RetrieverApp` owns UI; `Sources/RetrieverCore` owns testable connection and transfer behavior; `Tests/RetrieverCoreTests` owns XCTest cases. Explicit project membership is required for new files.
`make build`, `make build-universal`, `make test`, `make check-windows`, `make check-ssh`, `make check-browser`, `make run`, `make assets`, `make paths`, `make help`.
Generated output: `.build/`; inspected screenshots: `artifacts/verification/`; iteration plans: `docs/`.
Shared version and signing settings live in `Config/Signing.xcconfig`. Local credentials remain ignored. Unsigned development works without release credentials. Release pipeline is a later milestone and must not report success until signing/notarization and DMG validation pass.

## Working rules
- Implement the smallest coherent product slice first, then complete the requested workflow.
- Prefer native APIs and direct state changes over speculative abstractions.
- Preserve user work and avoid unrelated changes.
- Add focused tests for independently fallible behavior.
- Verify UI changes in the actual built app and inspect screenshot evidence.
- Keep credentials and iteration plans local; docs/ is ignored. Keep generated output isolated.
- Keep commands and this memory current as architecture changes.
- Create a new timestamped plan for every iteration. Commit finished milestones with short messages.

## SFTP core
`SFTPPacket.swift` implements bounded SFTP v3 decoding; `SFTPSession.swift` owns a synchronous process stream and must be used on one dedicated worker, never the main thread. Production uses system SSH with explicit new-host confirmation and rejection of changed keys. UI supplies the app executable as an askpass helper; headless callers use strict batch key/agent authentication. Test injection launches local sftp-server. Remote filenames retain raw bytes. Download publication uses an exclusively created sibling temporary file. The default uses non-replacing renamex_np(RENAME_EXCL); only an explicit replaceApproved policy from the accepted native Save dialog permits atomic replacement. Never unlink the destination first. Reject folder/symlink replacement destinations. `SFTPBrowser` owns the session on an actor with a dedicated Dispatch executor. UI operations pass a lock-protected cancellation signal; reads and writes poll every 100 ms and have a 30-second idle timeout. Complete ordinary server errors and local file errors preserve usable sessions. Cancellation between exchanges can retain the session after bounded handle cleanup; partial exchanges, malformed responses, timeouts, and transport errors invalidate it. The UI keeps the listing visible on errors and offers explicit Reconnect after actual connection loss. SSH diagnostic stderr is drained nonblockingly and capped at 16 KiB for transient error display. The app has an isolated `SSHAskpass` mode for native fingerprint/password/passphrase prompts. Credentials go only to the SSH stdout pipe. Helper exits when its parent SSH exits; negotiation allows five minutes.

## Brand assets
`Brand/Retriever-Logo-Approved.png` is the authoritative approved icon artwork. `Brand/Retriever-AppIcon.png` is the derived app-icon cutout with transparency outside the rounded cream tile. `Brand/RenderIcon.swift` resizes that cutout using AppKit, preserving its composition and alpha. `make assets` regenerates all ten tracked PNG slots and catalog metadata deterministically. Ordinary Xcode and Make builds consume tracked assets.

`make check-ssh` builds and tests the actual SSH transport against a disposable loopback sshd. It uses the same `SFTPSession.sshArguments` as production, with test-only identity and known-host paths. No personal/server credentials or SSH configuration changes are needed. Keep network integration separate from core XCTest.

`make check-browser` compiles production AppKit controller sources and uses an internal session factory to isolate fixture credentials. It verifies native connection/navigation and selected-file retrieval with an explicit destination; it does not prove native save confirmation or packaged-app authentication. The native save callback and `retrieveSelection(to:policy:)` integration entry point share the captured-node retrieval operation.

## Website release handoff
`make release` signs/notarizes and validates the app and DMG, requires the installed-copy verification, then publishes locally to `web-page/Retriever.dmg`, with checksum and release.json. Previous artifacts are backed up in ignored `docs/dmg-backups/`. Published website download buttons link directly to Retriever.dmg and work without JavaScript. Optional release metadata supplies the artifact version/checksum and must not gate download access. No website upload occurs. `python3 scripts/check_release_publication.py` tests output/backups without credentials.

## Saved hosts
`ConnectionHistory` is a main-actor store of successful host/account/port identities and raw folder bytes. `ConnectionSheet` provides the saved-host picker, New connection, editable Remote folder, and Forget. Save only after successful listing; update locations after successful navigation. Forgetting a connected host must not re-add it during navigation. SFTP reconnect falls back to home only on complete path-related server status responses; do not hide transport/authentication/cancellation errors. Inject isolated UserDefaults suites in checks.

## File tree and previews
The native outline lazily expands remote folders and retains raw paths for nested downloads. Right-click selects the pointed row and offers Download and Preview; folders/symlinks and busy operations disable these actions. Preview downloads into a private temporary folder and uses QLPreviewView in an auxiliary panel. Close Quick Look before removing its temporary file on close, replacement, or app termination. Preview cancellation uses the shared transfer cancellation path and removes its temporary directory.

## Keyboard and download history
Space previews the selected file only in the outline; Escape closes Preview or cancels its pending download. Keep outline focus and arrow navigation while gating remote actions during work. Previews above 1,000,000 bytes or of unknown size require confirmation; unapproved transfers enforce the same streaming limit for files that grew since listing. Existing previews remain until a replacement succeeds.

`DownloadHistory` persists successful user downloads (never previews or failed/cancelled attempts), including source identity/raw path, completion date, actual bytes, and a local file bookmark. Inject isolated defaults in checks. Downloads (⇧⌘J) opens a reusable window with Show in Finder and Clear History; clearing never deletes files. No credentials are stored. Tests cover connection recovery, explicit replacement, keyboard events, confirmation, and history; native Save/Replace and Finder interaction still require manual verification.
