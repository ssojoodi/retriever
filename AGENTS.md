# Retriever

Native SFTP browser with an embedded SSH terminal. Swift 6, AppKit, macOS 14+, Apple silicon only. Repository: https://github.com/ssojoodi/retriever. MIT licensed.

## Project rules

- Preserve user work; keep changes focused. Prefer native APIs and direct state changes.
- Create timestamped iteration plans in ignored `docs/`. Commit completed milestones with short messages.
- Add focused tests for fallible behavior. Verify UI changes in the built app and inspect screenshots.
- Keep credentials local and ignored. Generated output belongs in `.build/`; screenshots in `artifacts/verification/`.
- Keep this file and commands current. Do not record session history or machine-specific setup here.
- One retained browser window plus Help, Downloads, and Preview windows; closing the last window quits. Confirm active SSH termination and offer transfer cancellation before closing.
- Follow system appearance except for the always-dark terminal. FTP, folder transfers, remote deletion, synchronization, tabs, and App Store distribution are outside scope.

## Layout and verification

Xcode is authoritative; new files need explicit target membership. UI lives in `Sources/RetrieverApp`, testable behavior in `Sources/RetrieverCore`, and tests in `Tests`.

- `make build`, `make run`, `make build-release`: development and optimized arm64 builds.
- `make test`: core XCTest suite.
- `make check-ssh`: real SSH transport with isolated loopback credentials.
- `make check-browser`, `make check-terminal`, `make check-windows`: native UI and session checks.
- `python3 scripts/manual_browser_check.py --shell`: packaged-app fixture; native authentication, Save/Replace, and Finder interactions need manual verification.
- `python3 scripts/check_release_workflow.py` and `python3 scripts/check_release_publication.py`: release checks without signing credentials.

SwiftTerm is pinned in the Xcode project and Package.resolved. Builds require the Metal toolchain and one-time Xcode approval of its build-info plugin. Do not disable global plugin validation. Include ThirdPartyNotices.txt in the app bundle.

## Connections and transfers

- `SFTPSession` is synchronous and confined to `SFTPBrowser`’s dedicated actor executor, never the main thread. Preserve bounded SFTP v3 decoding and raw filename bytes.
- Use system SSH. Confirm new host keys and reject changed keys. Native `SSHAskpass` sends credentials only through the SSH stdout pipe and exits with its parent. Never persist passwords.
- Poll cancellation during I/O. Preserve usable sessions after complete server/local errors; invalidate partial exchanges, malformed responses, timeouts, and transport failures. Keep listings visible and offer Reconnect after connection loss.
- Downloads use exclusively created sibling temporary files. Default publication uses `renamex_np(RENAME_EXCL)`; only explicit `replaceApproved` from the native Save dialog permits atomic replacement. Never unlink the destination first or replace folders/symlinks.
- Upload only regular local files opened with `O_NOFOLLOW`. Use exclusive remote temporary files with mode 0600; acknowledge WRITE and CLOSE before publication. Default SFTP RENAME must not replace existing names.
- Upload replacement requires explicit approval, a regular target, and advertised `posix-rename@openssh.com` version 1. Never delete the target as a fallback. Bound cleanup; report possible leftover temporary files or uncertain publication after transport loss. Never automatically retry an uncertain upload. Refresh and select the uploaded file on success.

## Browser state

- Save successful host/account/port identities and raw folder paths only after successful listings. Do not auto-connect on launch or persist selection. Forgetting a connected host must not re-add it during navigation.
- Reconnect may fall back to home only after a complete path-related server error, never after authentication, transport, or cancellation errors.
- Keep raw paths for nested outline actions. Preserve keyboard focus and arrow navigation while gating remote actions during work.
- Space previews the selected file only in the outline. Escape closes Preview or cancels its download. Confirm sizes above 1,000,000 bytes or unknown sizes; enforce the streaming limit for unapproved files that grow.
- Keep the old preview until replacement succeeds. Close Quick Look before deleting its private temporary files on close, replacement, cancellation, or quit.
- Download history records only successful user downloads, with actual bytes and a local bookmark. Exclude previews, uploads, and failed/cancelled attempts. Clearing history never deletes files. Use isolated UserDefaults in tests.

## SSH terminal

`SSHTerminalViewController` embeds SwiftTerm in the browser viewport. Files/Terminal switching preserves SSH and browser state; restore focus to the visible view. Confirm replacement, End Session, and browser close/quit even when SSH is hidden. Reap the SSH child after bounded termination.

Folders target themselves; files target their parent; symlinks are disabled. `SSHLaunchRequest` quotes literal absolute UTF-8 paths, rejects control characters, and opens no shell if `cd` fails. Keep SSH independent of SFTP, use terminal authentication prompts, and deny remote clipboard requests. Terminal VoiceOver implementation is outside scope.

## Assets and releases

- Approved artwork: `Brand/Retriever-Logo-Approved.png`. The derived `Retriever-AppIcon.png` preserves transparency outside the rounded tile. `make assets` regenerates tracked icon slots; builds consume those assets.
- Versions and signing settings: `Config/Signing.xcconfig`. Increment the middle version number until 1.0.0; derive CURRENT_PROJECT_VERSION from MARKETING_VERSION, with no separate build counter.
- Bundle IDs: `ca.sahand.Retriever`, `ca.sahand.RetrieverCore`, `ca.sahand.RetrieverCoreTests`.
- Release uses arm64, `-Osize`, dead-code removal, and symbol stripping. Preserve matching app/core dSYMs outside the DMG.
- `make release` reuses its build cache, signs an isolated app and DMG, notarizes the DMG, and validates before local publication. Do not report success before checks pass. Back up previous artifacts in ignored `docs/dmg-backups/`.
- Website download links go directly to `web-page/Retriever.dmg` and work without JavaScript or release metadata. Release never uploads the website.
