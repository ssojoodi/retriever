# Functioning SFTP app handoff

## Summary
Initial repository setup and the requested minimal native SFTP browser/download workflow are complete. The blueprint explicitly separates development bootstrap from signed release readiness. No distributable release is claimed.

## Product behavior
Retriever connects using system SSH keys/agent or native authentication prompts, confirms new host keys, rejects changed keys, lists remote files, navigates folders and retrieves a selected file through a native Save dialog. Cancellation cleans partial downloads; exclusive publication preserves existing local files. One browser window, native menus, Help and About are implemented.

## Architecture
Xcode is authoritative for the AppKit executable, embedded Swift core framework and XCTest target. Commands, asset generation and local release driver are documented in README. Timestamped plans and modular commits retain the implementation history. No product changes in this final documentation iteration.

## Acceptance evidence
- Core XCTest result Test-Retriever-2026.09.28_23-29-43--0400.xcresult: 21 passed, zero failed/skipped; inspected again at handoff. No core changes since that result.
- Authenticated SSH fixture checks cover exact transfer bytes, trust rejection, encrypted-key authentication and errors.
- Updated authenticated controller check passed: connection sheet, folder/Up navigation, save cancellation, download bytes, occupied-destination preservation, disconnected error state and dismissal.
- Window checks passed: action routing/focus, minimum size, idle controller release, busy close cancellation/deferred cleanup and Help lifecycle.
- User confirmed the actual built app connected and downloaded the sample text file through native Save.
- Packaged native helper manually returned exact dummy passphrase, returned no bytes on Cancel, and passed the automated parent-exit pipe/lifetime check.
- User confirmed all four final checks: ⌘O/Escape; minimum-size toolbar access; About icon/name/version 0.1.0 build 1; ⌘W quits after closing About.
- Actual built-app browser screenshot and authenticated controller screenshot were opened and visually inspected. The latter is explicitly a harness screenshot, not packaged-app evidence.
- Fresh archive at commit 3af9278 built without local credentials/prior products; subsequent application change was the verified disconnected-title reset. Universal Release app/framework slices and macOS 14 deployment metadata were checked.
- git diff --check passed. Commit only these acceptance documents; preserve unrelated untracked Brand/Retriever-Logo-Approved.png and web-page/.

## Artifact paths
- Development app: .build/DerivedData/Build/Products/Debug/Retriever.app
- Actual app screenshot: artifacts/verification/browser-window.png
- Authenticated controller screenshot: artifacts/verification/authenticated-browser-display.png
- Test results: .build/DerivedData/Logs/Test/Test-Retriever-2026.09.28_23-29-43--0400.xcresult
- Latest controller log: .build/browser-error-check-rerun.log

## Limitations and next milestone
Development is unsigned. The release driver is implemented but full Developer ID signing, app/DMG notarization, mounted-copy verification and quarantine testing require verified credentials and remain unperformed. Confirm the inferred bundle namespace before distribution. Intel runtime, external-volume runtime and an external password-authenticated server were not tested. FTP, uploads, recursive downloads, symlink downloads, bookmarks and multi-connection windows are outside the initial product contract. No website changes or public publication were performed.

## Manual verification and cleanup
Manual test server, isolated agent and temporary private keys were removed. Normal accepted SSH host trust remains in known_hosts as disclosed. The user's final manual checks passed. Their new logo and website files were not altered or staged.
